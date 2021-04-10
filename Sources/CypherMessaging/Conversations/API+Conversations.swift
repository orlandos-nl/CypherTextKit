import CypherProtocol
import CypherTransport
import BSON
import Foundation
import NIO

extension CypherMessenger {
    public func getInternalConversation() -> EventLoopFuture<InternalConversation> {
        cachedStore.fetchConversations().flatMap { conversations in
            for conversation in conversations {
                let conversation = self._decrypt(conversation)
                
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
                    conversation: self._decrypt(conversation),
                    messenger: self
                )
            }
        }
    }
    
    public func getGroupChat(byId id: GroupChatId) -> EventLoopFuture<GroupChat?> {
        cachedStore.fetchConversations().flatMapThrowing { conversations in
            nextConversation: for conversation in conversations {
                let conversation = self._decrypt(conversation)
                if conversation.members.count < 2 || !conversation.members.contains(self.username) {
                    continue nextConversation
                }

                return GroupChat(
                    conversation: conversation,
                    messenger: self,
                    groupConfig: try BSONDecoder().decode(GroupChatConfig.self, from: conversation.metadata)
                )
            }
            
            return nil
        }
    }
    
    public func getPrivateChat(with otherUser: Username) -> EventLoopFuture<PrivateChat?> {
        cachedStore.fetchConversations().map { conversations in
            nextConversation: for conversation in conversations {
                let conversation = self._decrypt(conversation)
                
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
    
    public func createGroupChat(with users: Set<Username>) -> EventLoopFuture<GroupChat> {
        var members = users
        members.insert(username)
        let config = GroupChatConfig(
            members: members,
            admins: [self.username]
        )
        
        do {
            return self._createConversation(
                members: members,
                metadata: try BSONEncoder().encode(config)
            ).map { conversation in
                GroupChat(
                    conversation: self._decrypt(conversation),
                    messenger: self,
                    groupConfig: config
                )
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
                        conversation: self._decrypt(conversation),
                        messenger: self
                    )
                }
            }
        }
    }
    
    public func listPrivateChats(increasingOrder: @escaping (PrivateChat, PrivateChat) throws -> Bool) -> EventLoopFuture<[PrivateChat]> {
        cachedStore.fetchConversations().flatMapThrowing { conversations in
            return try conversations.compactMap { conversation -> PrivateChat? in
                let conversation = self._decrypt(conversation)
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
    var resolvedTarget: TargetConversation.Resolved { get }
}

extension AnyConversation {
    public func memberDevices() -> EventLoopFuture<[DecryptedModel<DeviceIdentity>]> {
        messenger._fetchDeviceIdentities(forUsers: conversation.members)
    }
    
    public func updateMetadata<Metadata: Encodable>(to metadata: Metadata) -> EventLoopFuture<Void> {
        do {
            conversation.metadata = try BSONEncoder().encode(metadata)
            return messenger.cachedStore.updateConversation(conversation.encrypted)
        } catch {
            return messenger.eventLoop.makeFailedFuture(error)
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
        self._sendMessage(
            CypherMessage(
                messageType: .text,
                messageSubtype: messageSubtype,
                text: text,
                metadata: metadata,
                destructionTimer: destructionTimer,
                sentDate: sentDate,
                preferredPushType: preferredPushType,
                order: conversation.props.getNextLocalOrder(),
                target: target
            ),
            to: conversation.members,
            pushType: preferredPushType
        )
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
            
            return messenger.cachedStore.createChatMessage(chatMessage).map {
                self.messenger._decrypt(chatMessage)
            }
        } catch {
            return messenger.eventLoop.makeFailedFuture(error)
        }
    }
    
    internal func _sendMessage(
        _ message: CypherMessage,
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
                return _saveMessage(
                    senderId: 0,
                    order: conversation.props.getNextLocalOrder(),
                    props: .init(
                        sending: message,
                        senderUser: self.messenger.username,
                        senderDeviceId: self.messenger.deviceId
                    )
                ).map { $0 }
            }
        }.flatMap { (chatMessage: DecryptedModel<ChatMessage>?) in
            messenger._queueTask(
                .sendMultiRecipientMessage(
                    SendMultiRecipientMessageTask(
                        message: message,
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
                        chatMessage: chatMessage
                    )
                } else {
                    return nil
                }
            }
        }
    }
    
    internal func _writeMessage(
        _ message: CypherMessage,
        to recipients: Set<Username>
    ) -> EventLoopFuture<Void> {
        let allMessagesQueues = recipients.map { recipient -> EventLoopFuture<Void> in
            messenger._fetchDeviceIdentities(for: recipient).flatMap { devices in
                let recipientMessagesQueued = devices.map { device in
                    messenger._queueTask(
                        .sendMessage(
                            SendMessageTask(
                                message: message,
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
        let target = self.target
        return memberDevices().flatMap { devices in
            var messages = devices.map { device -> EventLoopFuture<[ChatMessage]> in
                messenger.cachedStore.listChatMessages(
                    inConversation: self.conversation.id,
                    senderId: device.props.senderId,
                    sortedBy: sortMode,
                    offsetBy: 0,
                    limit: .max
                )
            }
            
            messages.append(
                messenger.cachedStore.listChatMessages(
                    inConversation: self.conversation.id,
                    senderId: 0, // current device
                    sortedBy: sortMode,
                    offsetBy: 0,
                    limit: .max
                )
            )
            
            return EventLoopFuture.whenAllSucceed(messages, on: messenger.eventLoop).map { messages in
                messages.reduce([]) { lhs, rhs in
                    lhs + rhs.map { message in
                        return AnyChatMessage(
                            target: target,
                            messenger: messenger,
                            chatMessage: messenger._decrypt(message)
                        )
                    }
                }
            }
        }
    }
}

public struct InternalConversation: AnyConversation {
    public let conversation: DecryptedModel<Conversation>
    public let messenger: CypherMessenger
    public let target = TargetConversation.currentUser
    public var resolvedTarget: TargetConversation.Resolved {
        .internalChat(self)
    }
    
    public func sendInternalMessage(_ message: CypherMessage) -> EventLoopFuture<Void> {
        self._writeMessage(message, to: [messenger.username])
    }
}

public struct GroupChat: AnyConversation {
    public let conversation: DecryptedModel<Conversation>
    public let messenger: CypherMessenger
    public private(set) var groupConfig: GroupChatConfig
    public var target: TargetConversation {
        return .groupChat(groupConfig.groupChatId)
    }
    public var resolvedTarget: TargetConversation.Resolved {
        .groupChat(self)
    }
}

public struct PrivateChat: AnyConversation {
    public let conversation: DecryptedModel<Conversation>
    public let messenger: CypherMessenger
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
