import Crypto
import CypherProtocol
import BSON
import Foundation
import NIO

enum UserIdentityState {
    case consistent, newIdentity, changedIdentity
}

// TODO: Respect push notification preferences that other users apply on your chat
// TODO: Server-Side mute and even block another user
// TODO: Encrypted push notifs
@available(macOS 10.15, iOS 13, *)
internal extension CypherMessenger {
    @CryptoActor
    @discardableResult
    func _markMessage(byRemoteId remoteId: String, updatedBy user: Username, as newState: ChatMessageModel.DeliveryState) async throws -> MarkMessageResult {
        let message = try await cachedStore.fetchChatMessage(byRemoteId: remoteId)
        let decryptedMessage = try await self.decrypt(message)
        
        guard await decryptedMessage.props.senderUser == self.username else {
            throw CypherSDKError.badInput
        }
        
        let oldState = await decryptedMessage.deliveryState
        let result = try await decryptedMessage.transitionDeliveryState(to: newState)
        
        do {
            try await self._updateChatMessage(decryptedMessage)
            return result
        } catch {
            try await decryptedMessage.setProp(at: \.deliveryState, to: oldState)
            throw error
        }
    }
    
    @CryptoActor
    @discardableResult
    func _markMessage(byId id: UUID?, as newState: ChatMessageModel.DeliveryState) async throws -> MarkMessageResult {
        guard let id = id else {
            return .error
        }
        
        let message = try await cachedStore.fetchChatMessage(byId: id)
        let decryptedMessage = try await self.decrypt(message)
        let oldState = await decryptedMessage.deliveryState
        
        let result = try await decryptedMessage.transitionDeliveryState(to: newState)
        
        do {
            try await self._updateChatMessage(decryptedMessage)
            return result
        } catch {
            try await decryptedMessage.setProp(at: \.deliveryState, to: oldState)
            throw error
        }
    }
    
    @CryptoActor
    func _updateChatMessage(_ message: DecryptedModel<ChatMessageModel>) async throws {
        try await self.cachedStore.updateChatMessage(message.encrypted)
        await self.eventHandler.onMessageChange(
            AnyChatMessage(
                target: message.props.message.target,
                messenger: self,
                raw: message
            )
        )
    }
    
    @CryptoActor
    func _createConversation(
        members: Set<Username>,
        metadata: Document
    ) async throws -> ConversationModel {
        var members = members
        members.insert(self.username)
        let conversation = try ConversationModel(
            props: .init(
                members: members,
                kickedMembers: [],
                metadata: metadata,
                localOrder: 0
            ),
            encryptionKey: self.databaseEncryptionKey
        )
        
        try await cachedStore.createConversation(conversation)
        let decrypted = try await self.decrypt(conversation)
        guard let resolved = await TargetConversation.Resolved(conversation: decrypted, messenger: self) else {
            throw CypherSDKError.internalError
        }
        
        await self.eventHandler.onCreateConversation(resolved)
        return conversation
    }
    
    @CryptoActor
    func _queueTask(_ task: CypherTask) async throws {
        try await self.jobQueue.queueTask(task)
    }
    
    @CryptoActor
    func _queueTasks(_ task: [CypherTask]) async throws {
        try await self.jobQueue.queueTasks(task)
    }
    
    @CryptoActor
    @discardableResult
    func _updateUserIdentity(of username: Username, to config: UserConfig) async throws -> UserIdentityState {
        if username == self.username {
            return .consistent
        }
        
        let contacts = try await cachedStore.fetchContacts()
        for contact in contacts {
            let contact = try await self.decrypt(contact)
            
            guard await contact.props.username == username else {
                continue
            }
            
            if await contact.config.identity.data == config.identity.data {
                return .consistent
            } else {
                try await contact.updateConfig(to: config)
                try await self.cachedStore.updateContact(contact.encrypted)
                return .changedIdentity
            }
        }
        
        let metadata = try await self.eventHandler.createContactMetadata(
            for: username,
            messenger: self
        )
        
        let contact = try ContactModel(
            props: ContactModel.SecureProps(
                username: username,
                config: config,
                metadata: metadata
            ),
            encryptionKey: self.databaseEncryptionKey
        )
        
        try await self.cachedStore.createContact(contact)
        await self.eventHandler.onCreateContact(
            Contact(messenger: self, model: try self.decrypt(contact)),
            messenger: self
        )
        return .newIdentity
    }
    
    @CryptoActor
    @discardableResult
    func _createDeviceIdentity(
        from device: UserDeviceConfig,
        forUsername username: Username,
        serverVerified: Bool = true
    ) async throws -> _DecryptedModel<DeviceIdentityModel> {
        let deviceIdentities = try await cachedStore.fetchDeviceIdentities()
        var knownSenderIds = [Int]()
        for deviceIdentity in deviceIdentities {
            let deviceIdentity = try self._decrypt(deviceIdentity)
            
            if
                deviceIdentity.props.username == username,
                deviceIdentity.props.deviceId == device.deviceId
            {
                guard
                    deviceIdentity.publicKey == device.publicKey,
                    deviceIdentity.identity.data == device.identity.data
                else {
                    throw CypherSDKError.invalidSignature
                }
                
                return deviceIdentity
            }
            
            knownSenderIds.append(deviceIdentity.senderId)
        }
        
        if username == self.username && device.deviceId == self.deviceId {
            throw CypherSDKError.badInput
        }
        
        var newSenderId: Int
        knownSenderIds.append(deviceIdentityId)
        
        repeat {
            newSenderId = .random(in: 1..<Int.max)
        } while knownSenderIds.contains(newSenderId)
        
        let newDevice = try DeviceIdentityModel(
            props: .init(
                username: username,
                deviceId: device.deviceId,
                senderId: newSenderId,
                publicKey: device.publicKey,
                identity: device.identity,
                isMasterDevice: device.isMasterDevice,
                doubleRatchet: nil,
                serverVerified: serverVerified
            ),
            encryptionKey: self.databaseEncryptionKey
        )
        // New device
        // TODO: Emit notification?
        
        let decryptedDevice = try self._decrypt(newDevice)
        try await self.cachedStore.createDeviceIdentity(newDevice)
        
        if username == self.username {
            await eventHandler.onDeviceRegistery(device.deviceId, messenger: self)
        } else {
            await eventHandler.onOtherUserDeviceRegistery(username: username, deviceId: device.deviceId, messenger: self)
        }
        return decryptedDevice
    }
    
    @CryptoActor
    func _refreshDeviceIdentities(
        for username: Username
    ) async throws {
        let devices = try await self._fetchKnownDeviceIdentities(for: username)
        try await _rediscoverDeviceIdentities(for: username, knownDevices: devices)
    }
    
    // TODO: Rate limit
    @CryptoActor
    @discardableResult
    func _rediscoverDeviceIdentities(
        for username: Username,
        knownDevices: [_DecryptedModel<DeviceIdentityModel>]
    ) async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        let userConfig = try await self.transport.readKeyBundle(forUsername: username)
        return try await _processDeviceConfig(
            userConfig,
            forUername: username,
            knownDevices: knownDevices
        )
    }
    
    @CryptoActor
    @discardableResult
    func _processDeviceConfig(
        _ userConfig: UserConfig,
        forUername username: Username,
        knownDevices: [_DecryptedModel<DeviceIdentityModel>]
    ) async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        if rediscoveredUsernames.contains(username) {
            return knownDevices
        }
        
        rediscoveredUsernames.insert(username)
        
        let identityState = try await self._updateUserIdentity(
            of: username,
            to: userConfig
        )
        
        switch identityState {
        case .changedIdentity:
            await self.eventHandler.onContactIdentityChange(username: username, messenger: self)
            // TODO: Remove unknown devices?
            fallthrough
        case .consistent, .newIdentity:
            var models = [_DecryptedModel<DeviceIdentityModel>]()
            
            for device in try userConfig.readAndValidateDevices() {
                if let knownDevice = knownDevices.first(where: { $0.props.deviceId == device.deviceId }) {
                    // Known device, check that everything is consistent
                    // To prevent tampering
                    guard knownDevice.props.publicKey == device.publicKey else {
                        throw CypherSDKError.invalidUserConfig
                    }
                    
                    models.append(knownDevice)
                } else if username == self.username && device.deviceId == self.deviceId {
                    continue
                } else {
                    try await models.append(self._createDeviceIdentity(from: device, forUsername: username))
                }
            }
            
            return models
        }
    }
    
    @CryptoActor
    func _receiveMultiRecipientMessage(
        _ message: MultiRecipientCypherMessage,
        messageId: String,
        sender: Username,
        senderDevice: DeviceId,
        createdAt: Date?
    ) async throws {
        guard let key = message.keys.first(where: { key in
            return key.user == self.username && key.deviceId == self.deviceId
        }) else {
            return
        }
        
        return try await _receiveMessage(
            key.message,
            multiRecipientContainer: message.container,
            messageId: messageId,
            sender: sender,
            senderDevice: senderDevice,
            createdAt: createdAt
        )
    }
    
    private func requestResendMessage(
        messageId: String,
        sender: Username,
        senderDevice: DeviceId
    ) async throws {
        // Request message is resent
        let resendRequest = SingleCypherMessage(
            messageType: .magic,
            messageSubtype: "_/resend/message",
            text: messageId,
            metadata: [:],
            destructionTimer: nil,
            sentDate: nil,
            preferredPushType: PushType.none,
            order: 0,
            target: .otherUser(sender)
        )
        
        try await _queueTask(
            .sendMessage(
                SendMessageTask(
                    message: CypherMessage(message: resendRequest),
                    recipient: sender,
                    recipientDeviceId: senderDevice,
                    localId: nil,
                    pushType: .none,
                    messageId: UUID().uuidString
                )
            )
        )
    }
    
    @CryptoActor
    func _receiveMessage(
        _ inbound: RatchetedCypherMessage,
        multiRecipientContainer: MultiRecipientContainer?,
        messageId: String,
        sender: Username,
        senderDevice: DeviceId,
        createdAt: Date?
    ) async throws {
        // Receive message always retries, do we need to deal with decryption errors as a successful task execution
        // Otherwise the task will infinitely run
        // However, replies to this message may fail, and must then be retried
        let deviceIdentity = try await self._fetchDeviceIdentity(for: sender, deviceId: senderDevice)
        
        if
            let createdAt = createdAt,
            let lastRekey = deviceIdentity.props.lastRekey,
            createdAt <= lastRekey
        {
            // Ignore message, since it was sent in a previous conversation.
            return try await requestResendMessage(messageId: messageId, sender: sender, senderDevice: senderDevice)
        }
        
        let message: CypherMessage
        do {
            let data = try await deviceIdentity._readWithRatchetEngine(message: inbound, messenger: self)
            
            if let multiRecipientContainer = multiRecipientContainer {
                guard data.count == 32 else {
                    throw CypherSDKError.invalidMultiRecipientKey
                }
                
                let key = SymmetricKey(data: data)
                
                message = try multiRecipientContainer.readAndValidate(
                    type: CypherMessage.self,
                    usingIdentity: deviceIdentity.props.identity,
                    decryptingWith: key
                )
            } else {
                message = try BSONDecoder().decode(CypherMessage.self, from: Document(data: data))
            }
        } catch {
            // Message was corrupt or unusable
            return try await requestResendMessage(messageId: messageId, sender: sender, senderDevice: senderDevice)
        }
        
        func processMessage(_ message: SingleCypherMessage) async throws {
            return try await self._processMessage(
                message: message,
                remoteMessageId: messageId,
                sender: deviceIdentity
            )
        }

        debugLog("Decrypted message(s)")
        switch message.box {
        case .single(let message):
            return try await processMessage(message)
        case .array(let messages):
            for message in messages {
                try await processMessage(message)
            }
        }
    }
    
    @CryptoActor
    func _processMessage(
        message: SingleCypherMessage,
        remoteMessageId: String,
        sender: _DecryptedModel<DeviceIdentityModel>
    ) async throws {
        switch message.target {
        case .currentUser:
            guard
                sender.username == self.username,
                sender.deviceId != self.deviceId
            else {
                throw CypherSDKError.badInput
            }
            
            switch (message.messageType, message.messageSubtype ?? "") {
            case (.magic, "_/devices/announce"):
                guard sender.isMasterDevice else {
                    throw CypherSDKError.badInput
                }
                
                let deviceConfig = try BSONDecoder().decode(
                    UserDeviceConfig.self,
                    from: message.metadata
                )
                
                if deviceConfig.deviceId == self.deviceId {
                    // We're not going to add ourselves as a conversation partner
                    // But we will mark ourselves as a registered device
                    try await self.updateConfig { config in
                        config.registeryMode = deviceConfig.isMasterDevice ? .masterDevice : .childDevice
                    }
                    return
                }
                
                try await self._createDeviceIdentity(
                    from: deviceConfig,
                    forUsername: self.username
                )
                return
            case (.magic, let subType) where subType == "_/devices/rename":
                let rename = try BSONDecoder().decode(
                    MagicPackets.RenameDevice.self,
                    from: message.metadata
                )
                
                guard rename.deviceId != self.deviceId else {
                    // We don't rename ourselves, our identity is not stored like tat
                    return
                }
                
                let device = try await _fetchDeviceIdentity(for: username, deviceId: rename.deviceId)
                try device.updateDeviceName(to: rename.name)
                try await cachedStore.updateDeviceIdentity(device.encrypted)
            case (.magic, let subType) where subType.hasPrefix("_/p2p/0/"):
                if
                    let sentDate = message.sentDate,
                    abs(sentDate.timeIntervalSince(Date())) >= 15
                {
                    // Other client is likely not waiting for P2P anymore
                    return
                }
                
                return try await _processP2PMessage(
                    message,
                    remoteMessageId: remoteMessageId,
                    sender: sender
                )
            case (.magic, "_/ignore"):
                return
            case (.magic, "_/resend/message"):
                guard let encryptedMessage = try? await self.cachedStore.fetchChatMessage(byRemoteId: message.text) else {
                    return
                }
                
                let message = try await self.decrypt(encryptedMessage)
                
                guard message.encrypted.senderId == self.deviceIdentityId else {
                    // We're not the origin!
                    debugLog("\(sender.username) requested a message not sent by us")
                    return
                }
                
                // Check if this message was targetted at that useer
                // We're the current user, so answer is automatically 'yes'
                try await _queueTask(
                    .sendMessage(
                        SendMessageTask(
                            message: CypherMessage(message: message.message),
                            recipient: sender.username,
                            recipientDeviceId: sender.deviceId,
                            localId: nil,
                            pushType: .none,
                            messageId: message.encrypted.remoteId
                        )
                    )
                )
                
                return
            default:
                guard message.messageSubtype?.hasPrefix("_/") != true else {
                    debugLog("Unknown message subtype in cypher messenger namespace: ", message.messageSubtype as Any)
                    return
                }
                
                let conversation = try await self.getInternalConversation()
                let context = ReceivedMessageContext(
                    sender: DeviceReference(
                        username: sender.props.username,
                        deviceId: sender.props.deviceId
                    ),
                    messenger: self,
                    message: message,
                    conversation: .internalChat(conversation)
                )
                
                switch try await self.eventHandler.onReceiveMessage(context).raw {
                case .ignore:
                    return
                case .save:
                    let conversation = try await self.getInternalConversation()
                    guard let chatMessage = try await conversation._saveMessage(
                        senderId: sender.props.senderId,
                        order: message.order,
                        props: .init(
                            receiving: message,
                            sentAt: message.sentDate ?? Date(),
                            senderUser: sender.props.username,
                            senderDeviceId: sender.props.deviceId
                        ),
                        remoteId: remoteMessageId
                    ) else {
                        // Message was not saved, probably duplicate
                        return
                    }
                    
                    if await chatMessage.senderUser == self.username {
                        // Send by our device in this chat
                        return
                    }
                }
            }
        case .groupChat(let groupId):
            let group = try await self._openGroupChat(byId: groupId)
            
            if let subType = message.messageSubtype, subType.hasPrefix("_/") {
                switch subType {
                case "_/ignore":
                    // Do nothing, it's like a `ping` message without `pong` reply
                    return
                case "_/resend/message":
                    guard let group = try await getGroupChat(byId: groupId) else {
                        debugLog("\(sender.username) requested a message from an unknown group \(groupId)")
                        return
                    }
                    
                    // 1. Check if the user is a member
                    guard await group.conversation.members.contains(sender.username) else {
                        debugLog("\(sender.username) requested a message from group \(groupId) which they're not a member of")
                        return
                    }
                    
                    // TODO: 2. Check if the user has had access, I.E. participation date
                    guard let encryptedMessage = try? await self.cachedStore.fetchChatMessage(byRemoteId: message.text) else {
                        return
                    }
                    
                    let message = try await self.decrypt(encryptedMessage)
                    
                    guard message.encrypted.senderId == self.deviceIdentityId else {
                        // We're not the origin!
                        debugLog("\(sender.username) requested a message not sent by us")
                        return
                    }
                    
                    guard group.conversation.encrypted.id == message.encrypted.conversationId else {
                        debugLog("\(sender.username) requested a message from an unrelated chat")
                        return
                    }
                    
                    // Check if this message was targetted at that useer
                    // We're the current user, so answer is automatically 'yes'
                    try await _queueTask(
                        .sendMessage(
                            SendMessageTask(
                                message: CypherMessage(message: message.message),
                                recipient: sender.username,
                                recipientDeviceId: sender.deviceId,
                                localId: nil,
                                pushType: .none,
                                messageId: message.encrypted.remoteId
                            )
                        )
                    )
                    return
                default:
                    debugLog("Unknown message subtype in cypher messenger namespace: ", message.messageSubtype as Any)
                    return
                }
            }
            
            let context = ReceivedMessageContext(
                sender: DeviceReference(
                    username: sender.props.username,
                    deviceId: sender.props.deviceId
                ),
                messenger: self,
                message: message,
                conversation: .groupChat(group)
            )
                
            switch try await self.eventHandler.onReceiveMessage(context).raw {
            case .ignore:
                return
            case .save:
                guard let chatMessage = try await group._saveMessage(
                    senderId: sender.props.senderId,
                    order: message.order,
                    props: .init(
                        receiving: message,
                        sentAt: message.sentDate ?? Date(),
                        senderUser: sender.props.username,
                        senderDeviceId: sender.props.deviceId
                    ),
                    remoteId: remoteMessageId
                ) else {
                    // Message was not saved, probably duplicate
                    return
                }
                
                if await chatMessage.senderUser != self.username {
                    try await self.jobQueue.queueTask(
                        CypherTask.sendMessageDeliveryStateChangeTask(
                            SendMessageDeliveryStateChangeTask(
                                localId: chatMessage.id,
                                messageId: chatMessage.encrypted.remoteId,
                                recipient: chatMessage.props.senderUser,
                                deviceId: nil, // All devices should receive this change
                                newState: .received
                            )
                        )
                    )
                }
            }
        case .otherUser(let recipient):
            switch (message.messageType, message.messageSubtype ?? "") {
            case (.magic, let subType) where subType.hasPrefix("_/p2p/0/"):
                return try await _processP2PMessage(
                    message,
                    remoteMessageId: remoteMessageId,
                    sender: sender
                )
            case (.magic, "_/ignore"):
                return
            case (.magic, "_/devices/announce"):
                try await self._refreshDeviceIdentities(for: sender.username)
                return
            case (.magic, "_/resend/message"):
                guard let encryptedMessage = try? await self.cachedStore.fetchChatMessage(byRemoteId: message.text) else {
                    return
                }
                
                let message = try await self.decrypt(encryptedMessage)
                
                guard message.encrypted.senderId == self.deviceIdentityId else {
                    // We're not the origin!
                    debugLog("\(sender.username) requested a message not sent by us")
                    return
                }
                
                // Check if this message was targetted at that useer
                guard let privateChat = try await getPrivateChat(with: sender.username) else {
                    debugLog("\(sender.username) requested a message from an unknown private chat")
                    return
                }
                
                guard privateChat.conversation.encrypted.id == message.encrypted.conversationId else {
                    debugLog("\(sender.username) requested a message from an unrelated chat")
                    return
                }
                
                try await _queueTask(
                    .sendMessage(
                        SendMessageTask(
                            message: CypherMessage(message: message.message),
                            recipient: sender.username,
                            recipientDeviceId: sender.deviceId,
                            localId: nil,
                            pushType: .none,
                            messageId: message.encrypted.remoteId
                        )
                    )
                )
                return
            case (.magic, let subType), (.media, let subType), (.text, let subType):
                if subType.hasPrefix("_/") {
                    debugLog("Unknown message subtype in cypher messenger namespace: ", message.messageSubtype as Any)
                    return
                }
            }
            
            let chatName = sender.props.username == self.username ? recipient : sender.props.username
            
            debugLog("Processing received message")
            let privateChat = try await self.createPrivateChat(with: chatName)
            let context = ReceivedMessageContext(
                sender: DeviceReference(
                    username: sender.props.username,
                    deviceId: sender.props.deviceId
                ),
                messenger: self,
                message: message,
                conversation: .privateChat(privateChat)
            )
            
            switch try await self.eventHandler.onReceiveMessage(context).raw {
            case .ignore:
                debugLog("Received message is to be ignored")
                return
            case .save:
                debugLog("Received message is to be saved")
                guard let chatMessage = try await privateChat._saveMessage(
                    senderId: sender.props.senderId,
                    order: message.order,
                    props: .init(
                        receiving: message,
                        sentAt: message.sentDate ?? Date(),
                        senderUser: sender.props.username,
                        senderDeviceId: sender.props.deviceId
                    ),
                    remoteId: remoteMessageId
                ) else {
                    // Message was not saved, probably duplicate
                    return
                }
                
                if await chatMessage.senderUser != self.username {
                    try await self.jobQueue.queueTask(
                        CypherTask.sendMessageDeliveryStateChangeTask(
                            SendMessageDeliveryStateChangeTask(
                                localId: chatMessage.id,
                                messageId: chatMessage.encrypted.remoteId,
                                recipient: chatMessage.props.senderUser,
                                deviceId: nil, // All devices should receive this change
                                newState: .received
                            )
                        )
                    )
                }
            }
        }
    }
    
    @CryptoActor
    func _fetchKnownDeviceIdentities(
        for username: Username
    ) async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        try await cachedStore.fetchDeviceIdentities().asyncCompactMap { deviceIdentity in
            let deviceIdentity = try self._decrypt(deviceIdentity)
            
            if deviceIdentity.username == username {
                return deviceIdentity
            } else {
                return nil
            }
        }
    }
    
    @CryptoActor
    func _fetchKnownDeviceIdentity(
        for username: Username,
        deviceId: DeviceId
    ) async throws -> _DecryptedModel<DeviceIdentityModel>? {
        for deviceIdentity in try await cachedStore.fetchDeviceIdentities() {
            let deviceIdentity = try self._decrypt(deviceIdentity)
            
            if deviceIdentity.username == username, deviceIdentity.deviceId == deviceId {
                return deviceIdentity
            }
        }
        
        return nil
    }
    
    @CryptoActor
    func _fetchDeviceIdentity(
        for username: Username,
        deviceId: DeviceId
    ) async throws -> _DecryptedModel<DeviceIdentityModel> {
        let knownDevices = try await self._fetchKnownDeviceIdentities(for: username)
        if let device = knownDevices.first(where: { $0.props.deviceId == deviceId }) {
            return device
        }
        
        let rediscoveredDevices = try await self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices)
        if let device = rediscoveredDevices.first(where: { $0.deviceId == deviceId }) {
            return device
        } else {
            throw CypherSDKError.cannotFindDeviceConfig
        }
    }
    
    @CryptoActor
    func _fetchDeviceIdentities(
        for username: Username
    ) async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        let knownDevices = try await self._fetchKnownDeviceIdentities(for: username)
        if knownDevices.isEmpty && username != self.username && isOnline {
            return try await self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices)
        }
            
        return knownDevices
    }
    
    @CryptoActor
    func _fetchDeviceIdentities(
        forUsers usernames: Set<Username>
    ) async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        let devices = try await cachedStore.fetchDeviceIdentities()
        let knownDevices = try await devices.asyncCompactMap { deviceIdentity -> _DecryptedModel<DeviceIdentityModel>? in
            let deviceIdentity = try self._decrypt(deviceIdentity)
            
            if usernames.contains(deviceIdentity.username) {
                return deviceIdentity
            } else {
                return nil
            }
        }
        
        var newDevices = [_DecryptedModel<DeviceIdentityModel>]()
        for username in usernames {
            if username != self.username, !knownDevices.contains(where: {
                $0.props.username == username
            }), isOnline {
                let rediscovered = try await self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices)
                newDevices.append(contentsOf: rediscovered)
            }
        }
        
        var allDevices = knownDevices
        
        for newDevice in newDevices {
            if !allDevices.contains(where: { device in
                device.props.username == newDevice.props.username && device.props.deviceId == newDevice.props.deviceId
            }) {
                allDevices.append(newDevice)
            }
        }
        
        return allDevices
    }
}
