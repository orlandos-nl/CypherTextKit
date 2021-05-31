import CypherProtocol
import BSON
import Foundation
import NIO

extension CypherMessenger {
    public func getInternalConversation() -> EventLoopFuture<InternalConversation> {
        cachedStore.fetchConversations().flatMap { conversations in
            for conversation in conversations {
                let conversation = self.decrypt(conversation)
                
                if conversation.members == [self.username] {
                    let internalChat = InternalConversation(conversation: conversation, messenger: self)
                    return self.eventLoop.makeSucceededFuture(internalChat)
                }
            }
            
            return self._createConversation(
                members: [self.username],
                metadata: [:]
            ).map { conversation in
                InternalConversation(
                    conversation: self.decrypt(conversation),
                    messenger: self
                )
            }
        }
    }
    
    internal func _openGroupChat(byId id: GroupChatId) -> EventLoopFuture<GroupChat> {
        getGroupChat(byId: id).flatMap { groupChat in
            if let groupChat = groupChat {
                return self.eventLoop.makeSucceededFuture(groupChat)
            }
            
            return self.transport.readPublishedBlob(
                byId: id.raw,
                as: Signed<GroupChatConfig>.self
            ).flatMap { config in
                guard let config = config else {
                    return self.eventLoop.makeFailedFuture(CypherSDKError.unknownGroup)
                }
                
                do {
                    let groupConfig = try config.blob.readWithoutVerifying()
                    
                    return self._fetchDeviceIdentities(for: groupConfig.admin).flatMap { devices in
                        for device in devices {
                            if config.blob.isSigned(by: device.props.identity) {
                                do {
                                    let config = ReferencedBlob(id: config.id, blob: groupConfig)
                                    let groupMetadata = GroupMetadata(
                                        custom: [:],
                                        config: config
                                    )
                                    let conversation = try Conversation(
                                        props: .init(
                                            members: groupConfig.members,
                                            metadata: BSONEncoder().encode(groupMetadata),
                                            localOrder: 0
                                        ),
                                        encryptionKey: self.databaseEncryptionKey
                                    )
                                    
                                    return self.cachedStore.createConversation(conversation).map {
                                        GroupChat(
                                            conversation: self.decrypt(conversation),
                                            messenger: self,
                                            metadata: groupMetadata
                                        )
                                    }
                                } catch {
                                    return self.eventLoop.makeFailedFuture(error)
                                }
                            }
                        }
                        
                        return self.eventLoop.makeFailedFuture(CypherSDKError.invalidGroupConfig)
                    }
                } catch {
                    return self.eventLoop.makeFailedFuture(error)
                }
            }
        }
    }
    
    public func getGroupChat(byId id: GroupChatId) -> EventLoopFuture<GroupChat?> {
        cachedStore.fetchConversations().flatMapThrowing { conversations in
            nextConversation: for conversation in conversations {
                let conversation = self.decrypt(conversation)
                if conversation.members.count < 2 || !conversation.members.contains(self.username) {
                    continue nextConversation
                }
                
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
            }
            
            return nil
        }
    }
    
    public func getPrivateChat(with otherUser: Username) -> EventLoopFuture<PrivateChat?> {
        cachedStore.fetchConversations().map { conversations in
            nextConversation: for conversation in conversations {
                let conversation = self.decrypt(conversation)
                
                if
                    conversation.members.count != 2
                        || !conversation.members.contains(self.username)
                        || !conversation.members.contains(otherUser)
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
    }
    
    public func createGroupChat(
        with users: Set<Username>,
        localMetadata: Document = [:],
        sharedMetadata: Document = [:]
    ) -> EventLoopFuture<GroupChat> {
        var members = users
        members.insert(username)
        let config = GroupChatConfig(
            admin: self.username,
            members: members,
            moderators: [self.username],
            metadata: sharedMetadata
        )
        
        do {
            return try self.transport.publishBlob(
                self.sign(config)
            ).flatMapThrowing { referencedBlob in
                let metadata = GroupMetadata(
                    custom: localMetadata,
                    config: ReferencedBlob(
                        id: referencedBlob.id,
                        blob: config
                    )
                )
            
                let metadataDocument = try BSONEncoder().encode(metadata)
                
                return (metadata, metadataDocument)
            }.flatMap { (metadata, metadataDocument) in
                return self._createConversation(
                    members: members,
                    metadata: metadataDocument
                ).map { conversation in
                    GroupChat(
                        conversation: self.decrypt(conversation),
                        messenger: self,
                        metadata: metadata
                    )
                }
            }
            
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }
    
    public func createPrivateChat(with otherUser: Username) -> EventLoopFuture<PrivateChat> {
        guard otherUser != self.username else {
            return eventLoop.makeFailedFuture(CypherSDKError.badInput)
        }
        
        return self.getPrivateChat(with: otherUser).flatMap { conversation -> EventLoopFuture<PrivateChat> in
            if let conversation = conversation {
                return self.eventLoop.makeSucceededFuture(conversation)
            } else {
                return self.eventHandler.privateChatMetadata(
                    withUser: otherUser
                ).flatMap { metadata in
                    self._createConversation(
                        members: [otherUser],
                        metadata: metadata
                    )
                }.map { conversation in
                    PrivateChat(
                        conversation: self.decrypt(conversation),
                        messenger: self
                    )
                }
            }
        }
    }
    
    public func listPrivateChats(increasingOrder: @escaping (PrivateChat, PrivateChat) throws -> Bool) -> EventLoopFuture<[PrivateChat]> {
        cachedStore.fetchConversations().flatMapThrowing { conversations in
            return try conversations.compactMap { conversation -> PrivateChat? in
                let conversation = self.decrypt(conversation)
                guard
                    conversation.members.contains(self.username),
                    conversation.members.count == 2
                else {
                    return nil
                }
                
                return PrivateChat(conversation: conversation, messenger: self)
            }.sorted(by: increasingOrder)
        }
    }
}

public protocol AnyConversation {
    var conversation: DecryptedModel<Conversation> { get }
    var messenger: CypherMessenger { get }
    var target: TargetConversation { get }
    var metadataContainer: MetadataContainer { get }
    var resolvedTarget: TargetConversation.Resolved { get }
}

extension AnyConversation {
    public func getOpenP2PConnections() -> EventLoopFuture<[P2PClient]> {
        return self.memberDevices().flatMap { devices in
            let connections = devices.map { device in
                return self.messenger.getEstablishedP2PConnection(with: device)
            }
            
            return EventLoopFuture.whenAllSucceed(connections, on: self.messenger.eventLoop).map { connections in
                return connections.compactMap { $0 }
            }
        }
    }
    
    public func buildP2PConnections(
        preferredTransportIdentifier: String? = nil
    ) -> EventLoopFuture<Void> {
        return self.memberDevices().flatMap { devices in
            let created = devices.map { device in
                return self.messenger.createP2PConnection(
                    with: device,
                    targetConversation: self.target,
                    preferredTransportIdentifier: preferredTransportIdentifier
                )
            }
            
            return EventLoopFuture.andAllSucceed(created, on: self.messenger.eventLoop)
        }
    }
    
    // TODO: This _could_ be cached in `metadataContainer`
    public func memberDevices() -> EventLoopFuture<[DecryptedModel<DeviceIdentity>]> {
        messenger._fetchDeviceIdentities(forUsers: conversation.members)
    }
    
    public func save() -> EventLoopFuture<Void> {
        messenger.cachedStore.updateConversation(conversation.encrypted)
    }
    
    private func getNextLocalOrder() -> EventLoopFuture<Int> {
        let order = conversation.props.getNextLocalOrder()
        return messenger.cachedStore.updateConversation(conversation.encrypted).map {
            order
        }
    }
    
    public func sendRawMessage(
        type: CypherMessageType,
        messageSubtype: String? = nil,
        text: String,
        metadata: Document = [:],
        destructionTimer: TimeInterval? = nil,
        sentDate: Date = Date(),
        preferredPushType: PushType
    ) -> EventLoopFuture<AnyChatMessage?> {
        getNextLocalOrder().flatMap { order in
            self._sendMessage(
                SingleCypherMessage(
                    messageType: .text,
                    messageSubtype: messageSubtype,
                    text: text,
                    metadata: metadata,
                    destructionTimer: destructionTimer,
                    sentDate: sentDate,
                    preferredPushType: preferredPushType,
                    order: order,
                    target: target
                ),
                to: conversation.members,
                pushType: preferredPushType
            )
        }
    }
    
    internal func _saveMessage(
        senderId: Int,
        order: Int,
        props: ChatMessage.SecureProps,
        remoteId: String = UUID().uuidString
    ) -> EventLoopFuture<DecryptedModel<ChatMessage>> {
        do {
            let chatMessage = try ChatMessage(
                conversationId: conversation.id,
                senderId: senderId,
                order: order,
                remoteId: remoteId,
                props: props,
                encryptionKey: messenger.databaseEncryptionKey
            )
            
            return messenger.cachedStore.createChatMessage(chatMessage).flatMap {
                let message = self.messenger.decrypt(chatMessage)
                
                return self.messenger.eventHandler.onCreateChatMessage(
                    AnyChatMessage(
                        target: self.target,
                        messenger: self.messenger,
                        raw: message
                    )
                ).map { message }
            }
        } catch {
            return messenger.eventLoop.makeFailedFuture(error)
        }
    }
    
    internal func _sendMessage(
        _ message: SingleCypherMessage,
        to recipients: Set<Username>,
        pushType: PushType
    ) -> EventLoopFuture<AnyChatMessage?> {
        messenger.eventHandler.onSendMessage(
            SentMessageContext(
                recipients: recipients,
                messenger: messenger,
                message: message,
                conversation: resolvedTarget
            )
        ).flatMap { action in
            switch action.raw {
            case .send:
                return messenger.eventLoop.makeSucceededFuture(nil)
            case .saveAndSend:
                return getNextLocalOrder().flatMap { order in
                    _saveMessage(
                        senderId: messenger.deviceIdentityId,
                        order: order,
                        props: .init(
                            sending: message,
                            senderUser: self.messenger.username,
                            senderDeviceId: self.messenger.deviceId
                        )
                    ).map { $0 }
                }
            }
        }.flatMap { (chatMessage: DecryptedModel<ChatMessage>?) in
            messenger._queueTask(
                .sendMultiRecipientMessage(
                    SendMultiRecipientMessageTask(
                        message: CypherMessage(message: message),
                        // We _always_ attach a messageID so the protocol doesn't give away
                        // The precense of magic packets
                        messageId: chatMessage?.encrypted.remoteId ?? UUID().uuidString,
                        recipients: recipients,
                        localId: chatMessage?.id,
                        pushType: pushType
                    )
                )
            ).flatMap {
                messenger.cachedStore.updateConversation(conversation.encrypted)
            }.map { () -> AnyChatMessage? in
                if let chatMessage = chatMessage {
                    return AnyChatMessage(
                        target: self.target,
                        messenger: messenger,
                        raw: chatMessage
                    )
                } else {
                    return nil
                }
            }
        }
    }
    
    internal func _writeMessage(
        _ message: SingleCypherMessage,
        to recipients: Set<Username>
    ) -> EventLoopFuture<Void> {
        let allMessagesQueues = recipients.map { recipient -> EventLoopFuture<Void> in
            messenger._fetchDeviceIdentities(for: recipient).flatMap { devices in
                let recipientMessagesQueued = devices.map { device in
                    messenger._queueTask(
                        .sendMessage(
                            SendMessageTask(
                                message: CypherMessage(message: message),
                                recipient: recipient,
                                recipientDeviceId: device.props.deviceId,
                                localId: nil,
                                messageId: ""
                            )
                        )
                    )
                }
                
                return EventLoopFuture.andAllSucceed(recipientMessagesQueued, on: self.messenger.eventLoop)
            }
        }
        
        return EventLoopFuture.andAllSucceed(allMessagesQueues, on: self.messenger.eventLoop)
    }
    
    public func allMessages(sortedBy sortMode: SortMode) -> EventLoopFuture<[AnyChatMessage]> {
        return cursor(sortedBy: sortMode).flatMap { cursor in
            cursor.getMore(.max)
        }
    }
    
    public func cursor(sortedBy sortMode: SortMode) -> EventLoopFuture<AnyChatMessageCursor> {
        AnyChatMessageCursor.readingConversation(self)
    }
}

public struct InternalConversation: AnyConversation {
    public let conversation: DecryptedModel<Conversation>
    public let messenger: CypherMessenger
    public let target = TargetConversation.currentUser
    public let metadataContainer = MetadataContainer()
    public var resolvedTarget: TargetConversation.Resolved {
        .internalChat(self)
    }
    
    public func sendInternalMessage(_ message: SingleCypherMessage) -> EventLoopFuture<Void> {
        self._writeMessage(message, to: [messenger.username])
    }
}

public struct GroupChat: AnyConversation {
    public let conversation: DecryptedModel<Conversation>
    public let messenger: CypherMessenger
    public var metadata: GroupMetadata
    public let metadataContainer = MetadataContainer()
    public var groupConfig: ReferencedBlob<GroupChatConfig> {
        metadata.config
    }
    public var target: TargetConversation {
        return .groupChat(GroupChatId(groupConfig.id))
    }
    
    public var resolvedTarget: TargetConversation.Resolved {
        .groupChat(self)
    }
}

public struct GroupMetadata: Codable {
    public var custom: Document
    public internal(set) var config: ReferencedBlob<GroupChatConfig>
}

public struct PrivateChat: AnyConversation {
    public let conversation: DecryptedModel<Conversation>
    public let messenger: CypherMessenger
    public let metadataContainer = MetadataContainer()
    public var target: TargetConversation {
        .otherUser(conversationPartner)
    }
    public var resolvedTarget: TargetConversation.Resolved {
        .privateChat(self)
    }
    
    public var conversationPartner: Username {
        // PrivateChats always have exactly 2 members
        var members = conversation.members
        members.remove(messenger.username)
        return members.first!
    }
}
