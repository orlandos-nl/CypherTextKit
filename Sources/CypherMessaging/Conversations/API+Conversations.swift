import CypherProtocol
@preconcurrency import BSON
import Foundation
import TaskQueue
import NIO

@available(macOS 10.15, iOS 13, *)
extension CypherMessenger {
    public func getConversation(byId id: UUID) async throws -> TargetConversation.Resolved? {
        let conversations = try await cachedStore.fetchConversations()
        for conversation in conversations {
            let conversation = try await self.decrypt(conversation)
            
            if conversation.id == id {
                return await TargetConversation.Resolved(
                    conversation: conversation,
                    messenger: self
                )
            }
        }
        
        return nil
    }
    
    @MainActor public func getInternalConversation() async throws -> InternalConversation {
        try await taskQueue.runThrowing { @MainActor in
            let conversations = try await self.cachedStore.fetchConversations()
            for conversation in conversations {
                let conversation = try self.decrypt(conversation)
                
                if conversation.members == [self.username] {
                    return InternalConversation(conversation: conversation, messenger: self)
                }
            }
            
            let conversation = try await self._createConversation(
                members: [self.username],
                metadata: [:]
            )
            
            return InternalConversation(
                conversation: try self.decrypt(conversation),
                messenger: self
            )
        }
    }
    
    internal func _openGroupChat(byId id: GroupChatId) async throws -> GroupChat {
        try await taskQueue.runThrowing { @MainActor in
            if let groupChat = try await self.getGroupChat(byId: id) {
                return groupChat
            }
            
            let config = try await self.transport.readPublishedBlob(
                byId: id.raw,
                as: Signed<GroupChatConfig>.self
            )
        
            guard let config = config else {
                throw CypherSDKError.unknownGroup
            }
            
            let groupConfig = try config.blob.readWithoutVerifying()
            
            let devices = try await self._fetchDeviceIdentities(for: groupConfig.admin)
            for device in devices {
                if await config.blob.isSigned(by: device.props.identity) {
                    let config = ReferencedBlob(id: config.id, blob: groupConfig)
                    let groupMetadata = GroupMetadata(
                        custom: [:],
                        config: config
                    )
                    let conversation = try ConversationModel(
                        props: .init(
                            members: groupConfig.members,
                            kickedMembers: [],
                            metadata: BSONEncoder().encode(groupMetadata),
                            localOrder: 0
                        ),
                        encryptionKey: self.databaseEncryptionKey
                    )
                    
                    try await self.cachedStore.createConversation(conversation)
                    let chat = GroupChat(
                        conversation: try self.decrypt(conversation),
                        messenger: self,
                        metadata: groupMetadata
                    )
                    self.eventHandler.onCreateConversation(chat)
                    return chat
                }
            }
                
            throw CypherSDKError.invalidGroupConfig
        }
    }
    
    @MainActor public func getGroupChat(byId id: GroupChatId) async throws -> GroupChat? {
        let conversations = try await cachedStore.fetchConversations()
        nextConversation: for conversation in conversations {
            let conversation = try self.decrypt(conversation)
            guard
                conversation.members.count >= 2,
                conversation.members.contains(self.username)
            else {
                continue nextConversation
            }
            
            do {
                let groupMetadata = try BSONDecoder().decode(
                    GroupMetadata.self,
                    from: conversation.metadata
                )
                
                if GroupChatId(groupMetadata.config.id) != id {
                    continue nextConversation
                }
                
                return GroupChat(
                    conversation: conversation,
                    messenger: self,
                    metadata: groupMetadata
                )
            } catch {
                continue nextConversation
            }
        }
        
        return nil
    }
    
    @MainActor public func getPrivateChat(with otherUser: Username) async throws -> PrivateChat? {
        let conversations = try await cachedStore.fetchConversations()
        nextConversation: for conversation in conversations {
            let conversation = try self.decrypt(conversation)
            let members = conversation.members
            
            if
                members.count != 2
                    || !members.contains(self.username)
                    || !members.contains(otherUser)
            {
                continue nextConversation
            }

            return PrivateChat(
                conversation: conversation,
                messenger: self
            )
        }
        
        return nil
    }
    
    public func createGroupChat(
        with users: Set<Username>,
        localMetadata: Document = [:],
        sharedMetadata: Document = [:]
    ) async throws -> GroupChat {
        var members = users
        members.insert(username)
        let config = GroupChatConfig(
            admin: self.username,
            members: members,
            moderators: [self.username],
            metadata: sharedMetadata
        )
        // TODO: Transparent Group Chats (no uploaded binary blobs)
        // TODO: Predefined group members?
        
        let referencedBlob = try await self.transport.publishBlob(self.sign(config))
        let metadata = GroupMetadata(
            custom: localMetadata,
            config: ReferencedBlob(
                id: referencedBlob.id,
                blob: config
            )
        )
    
        let metadataDocument = try BSONEncoder().encode(metadata)
        
        let conversation = try await self._createConversation(
            members: members,
            metadata: metadataDocument
        )
        
        let chat = GroupChat( 
            conversation: try await self.decrypt(conversation),
            messenger: self,
            metadata: metadata
        )
        
        try await chat.sendRawMessage(
            type: .magic,
            messageSubtype: "_/ignore",
            text: "",
            preferredPushType: .none
        )
        return chat
    }
    
    public func createPrivateChat(with otherUser: Username) async throws -> PrivateChat {
        try await taskQueue.runThrowing { @MainActor in
            guard otherUser != self.username else {
                throw CypherSDKError.badInput
            }
            
            if let conversation = try await self.getPrivateChat(with: otherUser) {
                return conversation
            } else {
                let metadata = try await self.eventHandler.createPrivateChatMetadata(
                    withUser: otherUser,
                    messenger: self
                )
                
                let conversation = try await self._createConversation(
                    members: [otherUser],
                    metadata: metadata
                )
                
                return PrivateChat(
                    conversation: try await self.decrypt(conversation),
                    messenger: self
                )
            }
        }
    }
    
    @MainActor public func listPrivateChats(increasingOrder: @escaping @Sendable @MainActor (PrivateChat, PrivateChat) throws -> Bool) async throws -> [PrivateChat] {
        let conversations = try await cachedStore.fetchConversations()
        return try await conversations.asyncCompactMap { conversation -> PrivateChat? in
            let conversation = try self.decrypt(conversation)
            let members = conversation.members
            guard
                members.contains(self.username),
                members.count == 2,
                conversation.metadata["_type"] as? String != "group"
            else {
                return nil
            }
            
            return PrivateChat(conversation: conversation, messenger: self)
        }.sorted { lhs, rhs in
            return try increasingOrder(lhs, rhs)
        }
    }
    
    @MainActor public func listGroupChats(increasingOrder: @escaping @Sendable @MainActor (GroupChat, GroupChat) throws -> Bool) async throws -> [GroupChat] {
        let conversations = try await cachedStore.fetchConversations()
        return try await conversations.asyncCompactMap { conversation -> GroupChat? in
            let conversation = try self.decrypt(conversation)
            let members = conversation.members
            
            guard
                members.contains(self.username),
                members.count >= 2,
                conversation.metadata["_type"] as? String == "group"
            else {
                return nil
            }
            
            do {
                let groupMetadata = try BSONDecoder().decode(
                    GroupMetadata.self,
                    from: conversation.metadata
                )
                
                return GroupChat(conversation: conversation, messenger: self, metadata: groupMetadata)
            } catch {
                return nil
            }
        }.sorted { lhs, rhs in
            return try increasingOrder(lhs, rhs)
        }
    }
    
    @MainActor public func listConversations(
        includingInternalConversation: Bool,
        increasingOrder: @escaping @Sendable @MainActor (TargetConversation.Resolved, TargetConversation.Resolved) throws -> Bool
    ) async throws -> [TargetConversation.Resolved] {
        let conversations = try await cachedStore.fetchConversations()
        
        return try await conversations.asyncCompactMap { conversation -> TargetConversation.Resolved? in
            let conversation = try self.decrypt(conversation)
            let resolved = await TargetConversation.Resolved(conversation: conversation, messenger: self)
            
            if !includingInternalConversation, case .internalChat = resolved {
                return nil
            }
            
            return resolved
        }.sorted { lhs, rhs in
            return try increasingOrder(lhs, rhs)
        }
    }
}

@available(macOS 10.15, iOS 13, *)
public protocol AnyConversation: Sendable {
    var conversation: DecryptedModel<ConversationModel> { get }
    var messenger: CypherMessenger { get }
    var cache: Cache { get }
    
    func getTarget() async -> TargetConversation
    func resolveTarget() async -> TargetConversation.Resolved
}

@available(macOS 10.15, iOS 13, *)
extension AnyConversation {
    public func listOpenP2PConnections() async throws -> [P2PClient] {
        try await self.memberDevices().asyncCompactMap { device in
            try await self.messenger.getEstablishedP2PConnection(with: device)
        }
    }
    
    /// Attempts to build connections with _all_ members of this chat.
    /// Should result in peer-to-peer connections with all currently active member devices.
    ///
    /// You can call this method when actively engaging in a conversation.
    /// Doing so will improve your connection performance and security
    public func buildP2PConnections(
        preferredTransportIdentifier: String? = nil
    ) async throws {
        for device in try await self.memberDevices() {
            try await self.messenger.createP2PConnection(
                with: device,
                targetConversation: self.getTarget(),
                preferredTransportIdentifier: preferredTransportIdentifier
            )
        }
    }
    
    // TODO: This _could_ be cached
    internal func memberDevices() async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        try await messenger._fetchDeviceIdentities(forUsers: conversation.members)
    }

    internal func historicMemberDevices() async throws -> [_DecryptedModel<DeviceIdentityModel>] {
        try await messenger._fetchDeviceIdentities(forUsers: conversation.allHistoricMembers)
    }
    
    @MainActor public func save() async throws {
        try await messenger.cachedStore.updateConversation(conversation.encrypted)
        messenger.eventHandler.onUpdateConversation(self)
    }
    
    internal func getNextLocalOrder() async throws -> Int {
        let order = try await conversation.getNextLocalOrder()
        try await messenger.cachedStore.updateConversation(conversation.encrypted)
        return order
    }
    
    @discardableResult
    @JobQueueActor public func sendRawMessage(
        type: CypherMessageType,
        messageSubtype: String? = nil,
        text: String,
        metadata: Document = [:],
        destructionTimer: TimeInterval? = nil,
        sentDate: Date = Date(),
        preferredPushType: PushType
    ) async throws -> AnyChatMessage? {
        let order = try await getNextLocalOrder()
        return try await self._sendMessage(
            SingleCypherMessage(
                messageType: type,
                messageSubtype: messageSubtype,
                text: text,
                metadata: metadata,
                destructionTimer: destructionTimer,
                sentDate: sentDate,
                preferredPushType: preferredPushType,
                order: order,
                target: getTarget()
            ),
            to: conversation.members,
            pushType: preferredPushType
        )
    }
    
    @discardableResult
    public func saveLocalMessage(
        type: CypherMessageType,
        messageSubtype: String? = nil,
        text: String,
        metadata: Document = [:],
        destructionTimer: TimeInterval? = nil,
        sentDate: Date = Date()
    ) async throws -> DecryptedModel<ChatMessageModel>? {
        let order = try await getNextLocalOrder()
        let message = await SingleCypherMessage(
            messageType: type,
            messageSubtype: messageSubtype,
            text: text,
            metadata: metadata,
            destructionTimer: destructionTimer,
            sentDate: sentDate,
            preferredPushType: .some(.none),
            order: order,
            target: getTarget()
        )
        
        return try await _saveMessage(
            senderId: messenger.deviceIdentityId,
            order: order,
            props: .init(
                sending: message,
                senderUser: self.messenger.username,
                senderDeviceId: self.messenger.deviceId
            )
        )
    }
    
    @CypherTextKitActor internal func _saveMessage(
        senderId: Int,
        order: Int,
        props: ChatMessageModel.SecureProps,
        remoteId: String = UUID().uuidString
    ) async throws -> DecryptedModel<ChatMessageModel>? {
        if let existingMessage = try? await messenger.cachedStore.fetchChatMessage(byRemoteId: remoteId) {
            let existingMessage = try await messenger.decrypt(existingMessage)
            
            if await existingMessage.senderUser == props.senderUser, await existingMessage.senderDeviceId == props.senderDeviceId {
                return nil
            } else {
                // TODO: Allow duplicate remote IDs, if they originate from different users
            }
        }
        
        let chatMessage = try ChatMessageModel(
            conversationId: conversation.id,
            senderId: senderId,
            order: order,
            remoteId: remoteId,
            props: props,
            encryptionKey: messenger.databaseEncryptionKey
        )
        
        try await messenger.cachedStore.createChatMessage(chatMessage)
        let message = try await self.messenger.decrypt(chatMessage)
        
        await self.messenger.eventHandler.onCreateChatMessage(
            AnyChatMessage(
                target: self.getTarget(),
                messenger: self.messenger,
                raw: message
            )
        )
        
        return message
    }
    
    @MainActor internal func _sendMessage(
        _ message: SingleCypherMessage,
        to recipients: Set<Username>,
        pushType: PushType
    ) async throws -> AnyChatMessage? {
        let action = try await messenger.eventHandler.onSendMessage(
            SentMessageContext(
                recipients: recipients,
                messenger: messenger,
                message: message,
                conversation: resolveTarget()
            )
        )
        
        var remoteId = UUID().uuidString
        var localId: UUID?
        var _chatMessage: DecryptedModel<ChatMessageModel>?
        
        switch action.raw {
        case .send:
            ()
        case .saveAndSend:
            guard let chatMessage = try await _saveMessage(
                senderId: messenger.deviceIdentityId,
                order: message.order,
                props: .init(
                    sending: message,
                    senderUser: self.messenger.username,
                    senderDeviceId: self.messenger.deviceId
                )
            ) else {
                // Message was not saved, probably an error
                // Let's abort to avoid confusion, while we can
                return nil
            }
            
            remoteId = chatMessage.encrypted.remoteId
            localId = chatMessage.id
            _chatMessage = chatMessage
        }
       
        if messenger.transport.supportsMultiRecipientMessages && messenger.isOnline {
            // If offline, try to leverage a potential peer-to-peer mesh
            try await messenger._queueTask(
                .sendMultiRecipientMessage(
                    SendMultiRecipientMessageTask(
                        message: CypherMessage(message: message),
                        // We _always_ attach a messageID so the protocol doesn't give away
                        // The precense of magic packets
                        messageId: remoteId,
                        recipients: recipients,
                        localId: localId,
                        pushType: pushType
                    )
                )
            )
        } else {
            var tasks = [CypherTask]()
            
            for device in try await memberDevices() {
                await tasks.append(
                    .sendMessage(
                        SendMessageTask(
                            message: CypherMessage(message: message),
                            recipient: device.username,
                            recipientDeviceId: device.deviceId,
                            localId: localId,
                            pushType: pushType,
                            messageId: remoteId
                        )
                    )
                )
            }
            
            try await messenger._queueTasks(tasks)
        }
        
        try await messenger.cachedStore.updateConversation(conversation.encrypted)
        
        if let chatMessage = _chatMessage {
            return await AnyChatMessage(
                target: self.getTarget(),
                messenger: messenger,
                raw: chatMessage
            )
        } else {
            return nil
        }
    }
    
    @MainActor public func message(byRemoteId remoteId: String) async throws -> AnyChatMessage {
        let message = try await self.messenger.cachedStore.fetchChatMessage(byRemoteId: remoteId)
        
        return await AnyChatMessage(
            target: self.getTarget(),
            messenger: self.messenger,
            raw: try self.messenger.decrypt(message)
        )
    }
    
    @MainActor public func message(byLocalId id: UUID) async throws -> AnyChatMessage {
        let message = try await self.messenger.cachedStore.fetchChatMessage(byId: id)
        
        return await AnyChatMessage(
            target: self.getTarget(),
            messenger: self.messenger,
            raw: try self.messenger.decrypt(message)
        )
    }
    
    @MainActor public func allMessages(sortedBy sortMode: SortMode) async throws -> [AnyChatMessage] {
        let cursor = try await cursor(sortedBy: sortMode)
        return try await cursor.getMore(.max)
    }

    @MainActor public func cursor(sortedBy sortMode: SortMode) async throws -> AnyChatMessageCursor {
        try await AnyChatMessageCursor.readingConversation(self)
    }
}

@available(macOS 10.15, iOS 13, *)
public struct InternalConversation: AnyConversation {
    public let conversation: DecryptedModel<ConversationModel>
    public let messenger: CypherMessenger
    @CacheActor public let cache = Cache()
    
    public func getTarget() async -> TargetConversation {
        return .currentUser
    }
    
    public func resolveTarget() async -> TargetConversation.Resolved {
        .internalChat(self)
    }
    
    public func sendInternalMessage(_ message: SingleCypherMessage) async throws {
        // Refresh device identities
        if messenger.isOnline {
            try await self.messenger._refreshDeviceIdentities(for: messenger.username)
        }
        
        try await messenger._writeMessage(message, to: messenger.username)
    }
    
    @JobQueueActor public func sendMagicPacket(
        messageSubtype: String,
        text: String,
        metadata: Document = [:],
        toDeviceId recipientDeviceId: DeviceId
    ) async throws {
        let order = try await getNextLocalOrder()
        try await messenger._queueTask(
            .sendMessage(
                SendMessageTask(
                    message: CypherMessage(
                        message: SingleCypherMessage(
                            messageType: .magic,
                            messageSubtype: messageSubtype,
                            text: text,
                            metadata: metadata,
                            sentDate: Date(),
                            preferredPushType: PushType.none,
                            order: order,
                            target: .currentUser
                        )
                    ),
                    recipient: messenger.username,
                    recipientDeviceId: recipientDeviceId,
                    localId: nil,
                    pushType: .none,
                    messageId: UUID().uuidString
                )
            )
        )
    }
    
    @JobQueueActor public func sendMagicPacket(
        messageSubtype: String,
        text: String,
        metadata: Document = [:]
    ) async throws {
        let order = try await getNextLocalOrder()
        _ = try await _sendMessage(
            SingleCypherMessage(
                messageType: .magic,
                messageSubtype: messageSubtype,
                text: text,
                metadata: metadata,
                sentDate: Date(),
                preferredPushType: PushType.none,
                order: order,
                target: .currentUser
            ),
            to: conversation.members,
            pushType: .none
        )
    }
}

@available(macOS 10.15, iOS 13, *)
public struct GroupChat: AnyConversation {
    public let conversation: DecryptedModel<ConversationModel>
    public let messenger: CypherMessenger
    internal var metadata: GroupMetadata
    @CacheActor public let cache = Cache()
    public func getGroupConfig() async -> ReferencedBlob<GroupChatConfig> {
        metadata.config
    }
    public func getGroupId() async -> GroupChatId {
        await GroupChatId(getGroupConfig().id)
    }
    
    public func getTarget() async -> TargetConversation {
        await .groupChat(getGroupId())
    }
    
    public func resolveTarget() async -> TargetConversation.Resolved {
        .groupChat(self)
    }
    
    @MainActor public func kickMember(_ member: Username) async throws {
        if !conversation.members.contains(member) {
            throw CypherSDKError.notGroupMember
        }

        try conversation.modifyProps { props in
            props.members.remove(member)
            props.kickedMembers.insert(member)
        }

        try await self.save()

        // Send message to user explicitly, so that they know they're kicked
        let order = try await getNextLocalOrder()
        try await messenger._writeMessage(
            SingleCypherMessage(
                messageType: .magic,
                messageSubtype: "_/group/kick",
                text: member.raw,
                metadata: [:],
                destructionTimer: nil,
                sentDate: Date(),
                preferredPushType: PushType.none,
                order: order,
                target: await self.getTarget()
            ),
            to: member
        )
        
        // TODO: Notify all members, update uploaded config
    }

    @MainActor public func inviteMember(_ member: Username) async throws {
        if conversation.members.contains(member) {
            return
        }

        try conversation.modifyProps { props in
            props.members.insert(member)
            props.kickedMembers.remove(member)
        }

        try await self.save()
        try await sendRawMessage(
            type: .magic,
            messageSubtype: "_/group/invite",
            text: member.raw,
            preferredPushType: .none
        )
        
        // TODO: Notify all members, update uploaded config
    }
}

public struct GroupMetadata: Codable, Sendable {
    public private(set) var _type = "group"
    public var custom: Document
    public internal(set) var config: ReferencedBlob<GroupChatConfig>
}

@available(macOS 10.15, iOS 13, *)
public struct PrivateChat: AnyConversation {
    public let conversation: DecryptedModel<ConversationModel>
    public let messenger: CypherMessenger
    @CacheActor public let cache = Cache()
    
    public func getTarget() async -> TargetConversation {
        .otherUser(await conversationPartner)
    }
    
    public func resolveTarget() -> TargetConversation.Resolved {
        .privateChat(self)
    }
    
    @MainActor public var conversationPartner: Username {
        // PrivateChats always have exactly 2 members
        var members = conversation.members
        members.remove(messenger.username)
        return members.first!
    }
    
    @discardableResult
    @JobQueueActor public func sendMagicPacketMessage(
        messageSubtype: String? = nil,
        text: String,
        metadata: Document = [:],
        preferredPushType: PushType
    ) async throws -> AnyChatMessage? {
        let order = try await getNextLocalOrder()
        return try await self._sendMessage(
            SingleCypherMessage(
                messageType: .magic,
                messageSubtype: messageSubtype,
                text: text,
                metadata: metadata,
                destructionTimer: nil,
                sentDate: Date(),
                preferredPushType: PushType.none,
                order: order,
                target: getTarget()
            ),
            to: [conversationPartner],
            pushType: .none
        )
    }
    
    @JobQueueActor public func sendMagicPacket(
        messageSubtype: String,
        text: String,
        metadata: Document = [:],
        toDeviceId recipientDeviceId: DeviceId
    ) async throws {
        let order = try await getNextLocalOrder()
        try await messenger._queueTask(
            .sendMessage(
                SendMessageTask(
                    message: CypherMessage(
                        message: SingleCypherMessage(
                            messageType: .magic,
                            messageSubtype: messageSubtype,
                            text: text,
                            metadata: metadata,
                            sentDate: Date(),
                            preferredPushType: PushType.none,
                            order: order,
                            target: .currentUser
                        )
                    ),
                    recipient: conversationPartner,
                    recipientDeviceId: recipientDeviceId,
                    localId: nil,
                    pushType: .none,
                    messageId: UUID().uuidString
                )
            )
        )
    }
}
