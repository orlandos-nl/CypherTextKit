import NIO
import CypherMessaging

public enum FriendshipStatus: Int, Codable {
    case undecided = 0, friend = 1
    case notFriend = 2
    case blocked = 3
}

fileprivate struct FriendshipMetadata: Codable {
    var ourPreBlockedState: FriendshipStatus?
    var ourState: FriendshipStatus
    var theirState: FriendshipStatus
    
    var contactBlocked: Bool {
        ourState == .blocked || theirState == .blocked
    }
    
    var mutualFriendship: Bool {
        switch (ourState, theirState) {
        case (.friend, .friend):
            return true
        case (.undecided, _), (_, .undecided), (.blocked, _), (_, .blocked), (.notFriend, _), (_, .notFriend):
            return false
        }
    }
}

fileprivate enum FriendshipPluginError: Error {
    case badInput
}

public struct FriendshipRuleset {
    public var ignoreWhenUndecided = true
    public var canIgnoreMagicPackets = true
    public var blockAffectsGroupChats = true
    public var preventSendingDisallowedMessages = true
    
    public init() {}
}

fileprivate struct ChangeFriendshipState: Codable {
    let newState: FriendshipStatus
    let subject: Username
}

public struct FriendshipPlugin: Plugin {
    public static let pluginIdentifier = "@/contacts/friendship"
    public let ruleset: FriendshipRuleset
    
    public init(ruleset: FriendshipRuleset) {
        self.ruleset = ruleset
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?> {
        let senderUsername = message.sender.username
        
        if case .groupChat = message.conversation.target {
            if ruleset.blockAffectsGroupChats, senderUsername != message.messenger.username {
                return message.messenger.createContact(byUsername: senderUsername).flatMap { contact in
                    if contact.contactBlocked {
                        return message.messenger.eventLoop.makeSucceededFuture(.ignore)
                    } else {
                        return message.messenger.eventLoop.makeSucceededFuture(nil)
                    }
                }
            }
            
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        if senderUsername == message.messenger.username {
            guard case .currentUser = message.conversation.target else {
                return message.messenger.eventLoop.makeSucceededFuture(nil)
            }
            
            if
                message.message.messageType == .magic,
                var subType = message.message.messageSubtype,
                subType.hasPrefix("@/contacts/friendship/")
            {
                subType.removeFirst("@/contacts/friendship/".count)
                
                switch subType {
                case "change-state":
                    let changedState: ChangeFriendshipState
                    
                    do {
                        changedState = try BSONDecoder().decode(ChangeFriendshipState.self, from: message.message.metadata)
                    } catch {
                        return message.messenger.eventLoop.makeFailedFuture(error)
                    }
        
                    return message.messenger.createContact(byUsername: changedState.subject).flatMap { contact in
                        contact.modifyMetadata(
                            ofType: FriendshipMetadata.self,
                            forPlugin: Self.self
                        ) { metadata in
                            metadata.ourState = changedState.newState
                            return .ignore
                        }
                    }
                default:
                    ()
                }
                
                return message.messenger.eventLoop.makeSucceededFuture(.ignore)
            }
        }
        
        return message.messenger.createContact(byUsername: senderUsername).flatMap { contact in
            if
                message.message.messageType == .magic,
                var subType = message.message.messageSubtype,
                subType.hasPrefix("@/contacts/friendship/")
            {
                subType.removeFirst("@/contacts/friendship/".count)
                
                switch subType {
                case "change-state":
                    let changedState: ChangeFriendshipState
                    
                    do {
                        changedState = try BSONDecoder().decode(ChangeFriendshipState.self, from: message.message.metadata)
                    } catch {
                        return message.messenger.eventLoop.makeFailedFuture(error)
                    }
                    
                    return contact.modifyMetadata(
                        ofType: FriendshipMetadata.self,
                        forPlugin: Self.self
                    ) { metadata in
                        metadata.theirState = changedState.newState
                        return .ignore
                    }
                default:
                    return message.messenger.eventLoop.makeSucceededFuture(.ignore)
                }
            }
            
            switch (contact.ourState, contact.theirState) {
            case (.blocked, _), (_, .blocked):
                return message.messenger.eventLoop.makeSucceededFuture(.ignore)
            case (.undecided, _), (_, .undecided):
                if message.message.messageType == .magic {
                    return message.messenger.eventLoop.makeSucceededFuture(
                        ruleset.canIgnoreMagicPackets ? .ignore : nil
                    )
                } else {
                    return message.messenger.eventLoop.makeSucceededFuture(
                        ruleset.ignoreWhenUndecided ? .ignore : nil
                    )
                }
            case (.friend, .friend):
                return message.messenger.eventLoop.makeSucceededFuture(nil)
            case (.notFriend, _), (_, .notFriend):
                return message.messenger.eventLoop.makeSucceededFuture(.ignore)
            }
        }
    }
    
    public func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction?> {
        return message.messenger.eventLoop.makeSucceededFuture(nil)
    }
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        do {
            let metadata = FriendshipMetadata(
                ourState: .undecided,
                theirState: .undecided
            )
            
            let document = try BSONEncoder().encode(metadata)
            return messenger.eventLoop.makeSucceededFuture(document)
        } catch {
            return messenger.eventLoop.makeFailedFuture(error)
        }
    }
    
    // Uninteresting events
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        // We don't store any metadata in PrivateChat right now
        // Contact is used instead
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
    
    public func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
}

extension Contact {
    public var ourState: FriendshipStatus {
        (try? self.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.ourState
        )) ?? .undecided
    }
    
    public var theirState: FriendshipStatus {
        (try? self.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.theirState
        )) ?? .undecided
    }
    
    public var mutualFriendship: Bool {
        (try? self.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.mutualFriendship
        )) ?? false
    }
    
    public var contactBlocked: Bool {
        (try? self.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.contactBlocked
        )) ?? false
    }
    
    public func block() -> EventLoopFuture<Void> {
        changeOurState(to: .blocked)
    }
    
    public func befriend() -> EventLoopFuture<Void> {
        changeOurState(to: .friend)
    }
    
    public func unfriend() -> EventLoopFuture<Void> {
        changeOurState(to: .notFriend)
    }
    
    public func unblock() -> EventLoopFuture<Void> {
        guard ourState == .blocked else {
            return self.eventLoop.makeSucceededVoidFuture()
        }
        
        let oldState = (try? self.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.ourPreBlockedState
        )) ?? .undecided
        
        return changeOurState(to: oldState)
    }
    
    fileprivate func changeOurState(to newState: FriendshipStatus) -> EventLoopFuture<Void> {
        self.modifyMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self
        ) { metadata in
            if newState == .blocked {
                if metadata.ourState == .blocked {
                    return
                }
                
                metadata.ourPreBlockedState = metadata.ourState
            }
            
            metadata.ourState = newState
        }.flatMapThrowing { () -> Document in
            try BSONEncoder().encode(
                ChangeFriendshipState(
                    newState: newState,
                    subject: self.username
                )
            )
        }.flatMap { message -> EventLoopFuture<Void> in
            self.messenger.getInternalConversation().flatMap { internalChat -> EventLoopFuture<Void> in
                internalChat.sendRawMessage(
                    type: .magic,
                    messageSubtype: "@/contacts/friendship/change-state",
                    text: "",
                    metadata: message,
                    preferredPushType: .none
                ).map { _ in }
            }.flatMap {
                self.messenger.createPrivateChat(with: self.username).flatMap { privateChat -> EventLoopFuture<Void> in
                    privateChat.sendRawMessage(
                        type: .magic,
                        messageSubtype: "@/contacts/friendship/change-state",
                        text: "",
                        metadata: message,
                        preferredPushType: .none
                    ).map { _ in }
                }
            }
        }
    }
}
