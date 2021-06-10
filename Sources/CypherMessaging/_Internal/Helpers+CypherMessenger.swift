import Crypto
import CypherProtocol
import BSON
import Foundation
import NIO

enum UserIdentityState {
    case consistent, newIdentity, changedIdentity
}

@available(macOS 12, iOS 15, *)
internal extension CypherMessenger {
    func _markMessage(byRemoteId remoteId: String, updatedBy user: Username, as newState: ChatMessageModel.DeliveryState) async throws -> MarkMessageResult {
        let message = try await cachedStore.fetchChatMessage(byRemoteId: remoteId)
        let decryptedMessage = try await message.decrypted(using: self.databaseEncryptionKey)
        
        guard decryptedMessage.props.senderUser == self.username else {
            throw CypherSDKError.badInput
        }
        
        let result = try await decryptedMessage.transitionDeliveryState(to: newState)
        self._updateChatMessage(decryptedMessage)
        return result
    }
    
    func _markMessage(byId id: UUID?, as newState: ChatMessageModel.DeliveryState) async throws -> MarkMessageResult {
        guard let id = id else {
            return .error
        }
        
        let message = try await cachedStore.fetchChatMessage(byId: id)
        let decryptedMessage = try await self.decrypt(message)
        
        let result = try await decryptedMessage.transitionDeliveryState(to: newState)
        
        self._updateChatMessage(decryptedMessage)
        return result
    }
    
    func _updateChatMessage(_ message: DecryptedModel<ChatMessageModel>) {
        self.eventHandler.onMessageChange(
            AnyChatMessage(
                target: message.props.message.target,
                messenger: self,
                raw: message
            )
        )
    }
    
    func _createConversation(
        members: Set<Username>,
        metadata: Document
    ) async throws -> ConversationModel {
        var members = members
        members.insert(self.username)
        let conversation = try ConversationModel(
            props: .init(
                members: members,
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
        
        self.eventHandler.onCreateConversation(resolved)
        return conversation
    }
    
    func _queueTask(_ task: CypherTask) async throws {
        try await self.jobQueue.queueTask(task)
    }
    
    func _updateUserIdentity(of username: Username, to config: UserConfig) async throws -> UserIdentityState {
        let contacts = try await cachedStore.fetchContacts()
        for contact in contacts {
            let contact = try await self.decrypt(contact)
            
            guard contact.props.username == username else {
                continue
            }
            
            if contact.config.identity.data == config.identity.data {
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
        return .newIdentity
    }
    
    func _createDeviceIdentity(from device: UserDeviceConfig, forUsername username: Username) async throws -> DecryptedModel<DeviceIdentityModel> {
        let deviceIdentities = try await cachedStore.fetchDeviceIdentities()
        for deviceIdentity in deviceIdentities {
            let deviceIdentity = try await self.decrypt(deviceIdentity)
            
            if
                deviceIdentity.props.username == username,
                deviceIdentity.props.deviceId == device.deviceId
            {
                return deviceIdentity
            }
        }
        
        if username == self.username && device.deviceId == self.deviceId {
            throw CypherSDKError.badInput
        }
        
        let newDevice = try DeviceIdentityModel(
            props: .init(
                username: username,
                deviceId: device.deviceId,
                senderId: .random(in: 1..<Int.max),
                publicKey: device.publicKey,
                identity: device.identity,
                doubleRatchet: nil
            ),
            encryptionKey: self.databaseEncryptionKey
        )
        // New device
        // TODO: Emit notification?
        
        let decryptedDevice = try await self.decrypt(newDevice)
        try await self.cachedStore.createDeviceIdentity(newDevice)
        return decryptedDevice
    }
    
    // TDOO: Rate limit
    func _rediscoverDeviceIdentities(
        for username: Username,
        knownDevices: [DecryptedModel<DeviceIdentityModel>]
    ) async throws -> [DecryptedModel<DeviceIdentityModel>] {
        let userConfig = try await self.transport.readKeyBundle(forUsername: username)
        let identityState = try await self._updateUserIdentity(
            of: username,
            to: userConfig
        )
        
        switch identityState {
        case .changedIdentity:
            self.eventHandler.onContactIdentityChange(username: username, messenger: self)
            fallthrough
        case .consistent, .newIdentity:
            var models = [DecryptedModel<DeviceIdentityModel>]()
            
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
    
    func _receiveMultiRecipientMessage(
        _ message: MultiRecipientCypherMessage,
        messageId: String,
        sender: Username,
        senderDevice: DeviceId
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
            senderDevice: senderDevice
        )
    }
    
    func _receiveMessage(
        _ message: RatchetedCypherMessage,
        multiRecipientContainer: MultiRecipientContainer?,
        messageId: String,
        sender: Username,
        senderDevice: DeviceId
    ) async throws {
        let (data, deviceIdentity) = try await self._readWithRatchetEngine(ofUser: sender, deviceId: senderDevice, message: message)
        let message: CypherMessage
        
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
        
        func processMessage(_ message: SingleCypherMessage) async throws {
            if let sentDate = message.sentDate, sentDate > Date() {
                // Message was sent in the future, which is impossible
                return
            }
            
            return try await self._processMessage(
                message: message,
                remoteMessageId: messageId,
                sender: deviceIdentity
            )
        }

        switch message.box {
        case .single(let message):
            return try await processMessage(message)
        case .array(let messages):
            for message in messages {
                try await processMessage(message)
            }
        }
    }
    
    private func _processMessage(
        message: SingleCypherMessage,
        remoteMessageId: String,
        sender: DecryptedModel<DeviceIdentityModel>
    ) async throws {
        switch message.target {
        case .currentUser:
            guard
                sender.username == self.username,
                sender.deviceId != self.deviceId
                // TODO: Check if `sender` is a master device
            else {
                throw CypherSDKError.badInput
            }
            
            switch (message.messageType, message.messageSubtype ?? "") {
            case (.magic, "_/devices/announce"):
                let deviceConfig = try BSONDecoder().decode(
                    UserDeviceConfig.self,
                    from: message.metadata
                )
                
                if deviceConfig.deviceId == self.deviceId {
                    // We're not going to add ourselves as a conversation partner
                    return
                }
                
                _ = try await self._createDeviceIdentity(
                    from: deviceConfig,
                    forUsername: self.username
                )
                return
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
            default:
                guard message.messageSubtype?.hasPrefix("_/") != true else {
                    debugLog("Unknown message subtype in cypher messenger namespace")
                    throw CypherSDKError.badInput
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
                    let chatMessage = try await conversation._saveMessage(
                        senderId: sender.props.senderId,
                        order: message.order,
                        props: .init(
                            receiving: message,
                            sentAt: message.sentDate ?? Date(),
                            senderUser: sender.props.username,
                            senderDeviceId: sender.props.deviceId
                        ),
                        remoteId: remoteMessageId
                    )
                    
                    return try await self.jobQueue.queueTask(
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
        case .groupChat(let groupId):
            guard message.messageSubtype?.hasPrefix("_/") != true else {
                debugLog("Unknown message subtype in cypher messenger namespace")
                throw CypherSDKError.badInput
            }
            
            let group = try await self._openGroupChat(byId: groupId)
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
                let chatMessage = try await group._saveMessage(
                    senderId: sender.props.senderId,
                    order: message.order,
                    props: .init(
                        receiving: message,
                        sentAt: message.sentDate ?? Date(),
                        senderUser: sender.props.username,
                        senderDeviceId: sender.props.deviceId
                    ),
                    remoteId: remoteMessageId
                )
                
                return try await self.jobQueue.queueTask(
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
        case .otherUser(let recipient):
            switch (message.messageType, message.messageSubtype ?? "") {
            case (.magic, let subType) where subType.hasPrefix("_/p2p/0/"):
                return try await _processP2PMessage(
                    message,
                    remoteMessageId: remoteMessageId,
                    sender: sender
                )
            case (.magic, let subType), (.media, let subType), (.text, let subType):
                if subType.hasPrefix("_/") {
                    debugLog("Unknown message subtype in cypher messenger namespace")
                    throw CypherSDKError.badInput
                }
            }
            
            let chatName = sender.props.username == self.username ? recipient : sender.props.username
            
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
                return
            case .save:
                let chatMessage = try await privateChat._saveMessage(
                    senderId: sender.props.senderId,
                    order: message.order,
                    props: .init(
                        receiving: message,
                        sentAt: message.sentDate ?? Date(),
                        senderUser: sender.props.username,
                        senderDeviceId: sender.props.deviceId
                    ),
                    remoteId: remoteMessageId
                )
                return try await self.jobQueue.queueTask(
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
    
    func _fetchKnownDeviceIdentities(
        for username: Username
    ) async throws -> [DecryptedModel<DeviceIdentityModel>] {
        try await cachedStore.fetchDeviceIdentities().asyncCompactMap { deviceIdentity in
            let deviceIdentity = try await self.decrypt(deviceIdentity)
            
            if deviceIdentity.username == username {
                return deviceIdentity
            } else {
                return nil
            }
        }
    }
    
    func _fetchDeviceIdentity(
        for username: Username,
        deviceId: DeviceId
    ) async throws -> DecryptedModel<DeviceIdentityModel> {
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
    
    func _fetchDeviceIdentities(
        for username: Username
    ) async throws -> [DecryptedModel<DeviceIdentityModel>] {
        let knownDevices = try await self._fetchKnownDeviceIdentities(for: username)
        if knownDevices.isEmpty, username != self.username {
            return try await self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices)
        }
            
        return knownDevices
    }
    
    @Sendable func _fetchDeviceIdentities(
        forUsers usernames: Set<Username>
    ) async throws -> [DecryptedModel<DeviceIdentityModel>] {
        let devices = try await cachedStore.fetchDeviceIdentities()
        let knownDevices = try await devices.asyncCompactMap { deviceIdentity -> DecryptedModel<DeviceIdentityModel>? in
            let deviceIdentity = try await self.decrypt(deviceIdentity)
            
            if usernames.contains(deviceIdentity.username) {
                return deviceIdentity
            } else {
                return nil
            }
        }
        
        var newDevices = [DecryptedModel<DeviceIdentityModel>]()
        for username in usernames {
            if username != self.username, await !knownDevices.asyncContains(where: {
                $0.props.username == username
            }) {
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
