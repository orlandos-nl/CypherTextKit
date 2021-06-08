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
    func _markMessage(byRemoteId remoteId: String, updatedBy user: Username, as newState: ChatMessageModel.DeliveryState) -> EventLoopFuture<MarkMessageResult> {
        return cachedStore.fetchChatMessage(byRemoteId: remoteId).flatMapThrowing { message in
            let decryptedMessage = message.decrypted(using: self.databaseEncryptionKey)
            
            guard decryptedMessage.props.senderUser == self.username else {
                throw CypherSDKError.badInput
            }
            
            let result = decryptedMessage.deliveryState.transition(to: newState)
            self._updateChatMessage(decryptedMessage)
            return result
        }
    }
    
    func _markMessage(byId id: UUID?, as newState: ChatMessageModel.DeliveryState) -> EventLoopFuture<MarkMessageResult> {
        guard let id = id else {
            return eventLoop.makeSucceededFuture(.error)
        }
        
        return cachedStore.fetchChatMessage(byId: id).map { message in
            let decryptedMessage = self.decrypt(message)
            
            let result = decryptedMessage.deliveryState.transition(to: newState)
            
            self._updateChatMessage(decryptedMessage)
            return result
        }
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
    ) -> EventLoopFuture<ConversationModel> {
        do {
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
            
            return cachedStore.createConversation(conversation).flatMapThrowing {
                let decrypted = self.decrypt(conversation)
                guard let resolved = TargetConversation.Resolved(conversation: decrypted, messenger: self) else {
                    throw CypherSDKError.internalError
                }
                
                self.eventHandler.onCreateConversation(resolved)
                return conversation
            }
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }
    
    func _queueTask(_ task: CypherTask) -> EventLoopFuture<Void> {
        self.jobQueue.queueTask(task)
    }
    
    func _updateUserIdentity(of username: Username, to config: UserConfig) -> EventLoopFuture<UserIdentityState> {
        cachedStore.fetchContacts().flatMap { contacts -> EventLoopFuture<UserIdentityState> in
            for contact in contacts {
                let contact = self.decrypt(contact)
                
                guard contact.props.username == username else {
                    continue
                }
                
                if contact.config.identity.data == config.identity.data {
                    return self.eventLoop.makeSucceededFuture(.consistent)
                } else {
                    contact.config = config
                    return self.cachedStore.updateContact(contact.encrypted).map {
                        .changedIdentity
                    }
                }
            }
            
            return self.eventLoop.executeAsync {
                try await self.eventHandler.createContactMetadata(
                    for: username,
                    messenger: self
                )
            }.flatMapThrowing { metadata in
                try ContactModel(
                    props: ContactModel.SecureProps(
                        username: username,
                        config: config,
                        metadata: metadata
                    ),
                    encryptionKey: self.databaseEncryptionKey
                )
            }.flatMap { contact in
                self.cachedStore.createContact(contact).map {
                    .newIdentity
                }
            }
        }
    }
    
    func _createDeviceIdentity(from device: UserDeviceConfig, forUsername username: Username) -> EventLoopFuture<DecryptedModel<DeviceIdentityModel>> {
        return cachedStore.fetchDeviceIdentities().flatMap { deviceIdentities in
            for deviceIdentity in deviceIdentities {
                let deviceIdentity = self.decrypt(deviceIdentity)
                
                if
                    deviceIdentity.props.username == username,
                    deviceIdentity.props.deviceId == device.deviceId
                {
                    return self.eventLoop.makeSucceededFuture(deviceIdentity)
                }
            }
            
            if username == self.username && device.deviceId == self.deviceId {
                return self.eventLoop.makeFailedFuture(CypherSDKError.badInput)
            }
            
            do {
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
                
                let decryptedDevice = self.decrypt(newDevice)
                return self.cachedStore.createDeviceIdentity(newDevice).map {
                    decryptedDevice
                }
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        }
    }
    
    func _rediscoverDeviceIdentities(
        for username: Username,
        knownDevices: [DecryptedModel<DeviceIdentityModel>]
    ) -> EventLoopFuture<[DecryptedModel<DeviceIdentityModel>]> {
        self.transport.readKeyBundle(forUsername: username).flatMap { userConfig in
            return self._updateUserIdentity(
                of: username,
                to: userConfig
            ).flatMapThrowing { identityState -> [EventLoopFuture<DecryptedModel<DeviceIdentityModel>>] in
                switch identityState {
                case .changedIdentity:
                    self.eventHandler.onContactIdentityChange(username: username, messenger: self)
                    fallthrough
                case .consistent, .newIdentity:
                    return try userConfig.readAndValidateDevices().compactMap { device -> EventLoopFuture<DecryptedModel<DeviceIdentityModel>>? in
                        if let knownDevice = knownDevices.first(where: { $0.props.deviceId == device.deviceId }) {
                            // Known device, check that everything is consistent
                            // To prevent tampering
                            guard knownDevice.props.publicKey == device.publicKey else {
                                fatalError()
                            }
                            
                            return self.eventLoop.makeSucceededFuture(knownDevice)
                        } else if username == self.username && device.deviceId == self.deviceId {
                            return nil
                        } else {
                            return self._createDeviceIdentity(from: device, forUsername: username)
                        }
                    }
                }
            }.flatMap { allDevices in
                EventLoopFuture.whenAllSucceed(allDevices, on: self.eventLoop)
            }
        }
    }
    
    func _receiveMultiRecipientMessage(
        _ message: MultiRecipientCypherMessage,
        messageId: String,
        sender: Username,
        senderDevice: DeviceId
    ) -> EventLoopFuture<Void> {
        guard let key = message.keys.first(where: { key in
            return key.user == self.username && key.deviceId == self.deviceId
        }) else {
            return eventLoop.makeSucceededVoidFuture()
        }
        
        return _receiveMessage(
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
    ) -> EventLoopFuture<Void> {
        self._readWithRatchetEngine(ofUser: sender, deviceId: senderDevice, message: message).flatMap { (data, deviceIdentity) -> EventLoopFuture<Void> in
            let message: CypherMessage
            
            if let multiRecipientContainer = multiRecipientContainer {
                guard data.count == 32 else {
                    return self.eventLoop.makeFailedFuture(CypherSDKError.invalidMultiRecipientKey)
                }
                
                let key = SymmetricKey(data: data)
                
                do {
                    message = try multiRecipientContainer.readAndValidate(
                        type: CypherMessage.self,
                        usingIdentity: deviceIdentity.props.identity,
                        decryptingWith: key
                    )
                } catch {
                    return self.eventLoop.makeFailedFuture(error)
                }
            } else {
                do {
                    message = try BSONDecoder().decode(CypherMessage.self, from: Document(data: data))
                } catch {
                    return self.eventLoop.makeFailedFuture(error)
                }
            }
            
            func processMessage(_ message: SingleCypherMessage) -> EventLoopFuture<Void> {
                if let sentDate = message.sentDate, sentDate > Date() {
                    // Message was sent in the future, which is impossible
                    return self.eventLoop.makeSucceededVoidFuture()
                }
                
                return self.eventLoop.executeAsync {
                    try await self._processMessage(
                        message: message,
                        remoteMessageId: messageId,
                        sender: deviceIdentity
                    )
                }
            }

            switch message.box {
            case .single(let message):
                return processMessage(message)
            case .array(let messages):
                return EventLoopFuture.andAllSucceed(messages.map(processMessage), on: self.eventLoop)
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
                sender.props.username == self.username &&
                    sender.props.deviceId != self.deviceId
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
                ).get()
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
                ).get()
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
                    return try await conversation._saveMessage(
                        senderId: sender.props.senderId,
                        order: message.order,
                        props: .init(
                            receiving: message,
                            sentAt: message.sentDate ?? Date(),
                            senderUser: sender.props.username,
                            senderDeviceId: sender.props.deviceId
                        ),
                        remoteId: remoteMessageId
                    ).flatMap { chatMessage in
                        return self.jobQueue.queueTask(
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
                    }.get()
                }
            }
        case .groupChat(let groupId):
            guard message.messageSubtype?.hasPrefix("_/") != true else {
                debugLog("Unknown message subtype in cypher messenger namespace")
                throw CypherSDKError.badInput
            }
            
            let group = try await self._openGroupChat(byId: groupId).get()
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
                return try await group._saveMessage(
                    senderId: sender.props.senderId,
                    order: message.order,
                    props: .init(
                        receiving: message,
                        sentAt: message.sentDate ?? Date(),
                        senderUser: sender.props.username,
                        senderDeviceId: sender.props.deviceId
                    ),
                    remoteId: remoteMessageId
                ).flatMap { chatMessage in
                    self.jobQueue.queueTask(
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
                }.get()
            }
        case .otherUser(let recipient):
            switch (message.messageType, message.messageSubtype ?? "") {
            case (.magic, let subType) where subType.hasPrefix("_/p2p/0/"):
                return try await _processP2PMessage(
                    message,
                    remoteMessageId: remoteMessageId,
                    sender: sender
                ).get()
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
                return try await privateChat._saveMessage(
                    senderId: sender.props.senderId,
                    order: message.order,
                    props: .init(
                        receiving: message,
                        sentAt: message.sentDate ?? Date(),
                        senderUser: sender.props.username,
                        senderDeviceId: sender.props.deviceId
                    ),
                    remoteId: remoteMessageId
                ).flatMap { chatMessage in
                    self.jobQueue.queueTask(
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
                }.get()
            }
        }
    }
    
    func _fetchKnownDeviceIdentities(
        for username: Username
    ) -> EventLoopFuture<[DecryptedModel<DeviceIdentityModel>]> {
        cachedStore.fetchDeviceIdentities().map { deviceIdentities in
            deviceIdentities.compactMap { deviceIdentity in
                let deviceIdentity = self.decrypt(deviceIdentity)
                
                if deviceIdentity.props.username == username {
                    return deviceIdentity
                } else {
                    return nil
                }
            }
        }
    }
    
    func _fetchDeviceIdentity(
        for username: Username,
        deviceId: DeviceId
    ) -> EventLoopFuture<DecryptedModel<DeviceIdentityModel>> {
        self._fetchKnownDeviceIdentities(for: username).flatMap { knownDevices in
            if let device = knownDevices.first(where: { $0.props.deviceId == deviceId }) {
                return self.eventLoop.makeSucceededFuture(device)
            }
            
            return self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices).flatMapThrowing { knownDevices in
                if let device = knownDevices.first(where: { $0.props.deviceId == deviceId }) {
                    return device
                } else {
                    print(self.username, username)
                    throw CypherSDKError.cannotFindDeviceConfig
                }
            }
        }
    }
    
    func _fetchDeviceIdentities(
        for username: Username
    ) -> EventLoopFuture<[DecryptedModel<DeviceIdentityModel>]> {
        self._fetchKnownDeviceIdentities(for: username).flatMap { knownDevices in
            if knownDevices.isEmpty, username != self.username {
                return self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices)
            }
            
            return self.eventLoop.makeSucceededFuture(knownDevices)
        }
    }
    
    func _fetchDeviceIdentities(
        forUsers usernames: Set<Username>
    ) -> EventLoopFuture<[DecryptedModel<DeviceIdentityModel>]> {
        cachedStore.fetchDeviceIdentities().map { deviceIdentities in
            deviceIdentities.compactMap { deviceIdentity -> DecryptedModel<DeviceIdentityModel>? in
                let deviceIdentity = self.decrypt(deviceIdentity)
                
                if usernames.contains(deviceIdentity.props.username) {
                    return deviceIdentity
                } else {
                    return nil
                }
            }
        }.flatMap { knownDevices in
            let rediscoveredDevices = usernames.map { username -> EventLoopFuture<[DecryptedModel<DeviceIdentityModel>]> in
                if username != self.username && !knownDevices.contains(where: {
                    $0.props.username == username
                }) {
                    return self._rediscoverDeviceIdentities(for: username, knownDevices: knownDevices)
                } else {
                    return self.eventLoop.makeSucceededFuture([])
                }
            }
            
            return EventLoopFuture.whenAllSucceed(rediscoveredDevices, on: self.eventLoop).map { newDevices in
                let newDevices = newDevices.joined()
                var allDevices = knownDevices
                
                for newDevice in newDevices {
                    if !allDevices.contains(where: { device in
                        return device.props.username == newDevice.props.username
                            && device.props.deviceId == newDevice.props.deviceId
                    }) {
                        allDevices.append(newDevice)
                    }
                }
                
                return allDevices
            }
        }
    }
}
