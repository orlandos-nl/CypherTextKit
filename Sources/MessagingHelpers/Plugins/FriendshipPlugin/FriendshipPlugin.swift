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

@available(macOS 12, iOS 15, *)
public struct FriendshipPlugin: Plugin {
    public static let pluginIdentifier = "@/contacts/friendship"
    public let ruleset: FriendshipRuleset
    
    public init(ruleset: FriendshipRuleset) {
        self.ruleset = ruleset
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        let senderUsername = message.sender.username
        let target = await message.conversation.getTarget()
        
        if case .groupChat = target {
            if ruleset.blockAffectsGroupChats, senderUsername != message.messenger.username {
                let contact = try await message.messenger.createContact(byUsername: senderUsername)
                if await contact.isContactBlocked() {
                    return .ignore
                } else {
                    return nil
                }
            }
            
            return nil
        }
        
        if senderUsername == message.messenger.username {
            guard case .currentUser = target else {
                return nil
            }
            
            if
                message.message.messageType == .magic,
                var subType = message.message.messageSubtype,
                subType.hasPrefix("@/contacts/friendship/")
            {
                subType.removeFirst("@/contacts/friendship/".count)
                
                switch subType {
                case "change-state":
                    let changedState = try BSONDecoder().decode(ChangeFriendshipState.self, from: message.message.metadata)
                    
                    let contact = try await message.messenger.createContact(byUsername: changedState.subject)
                    return try await contact.modifyMetadata(
                        ofType: FriendshipMetadata.self,
                        forPlugin: Self.self
                    ) { metadata in
                        metadata.ourState = changedState.newState
                        return .ignore
                    }
                default:
                    ()
                }
                
                return .ignore
            }
        }
        
        let contact = try await message.messenger.createContact(byUsername: senderUsername)
        
        if
            message.message.messageType == .magic,
            var subType = message.message.messageSubtype,
            subType.hasPrefix("@/contacts/friendship/")
        {
            subType.removeFirst("@/contacts/friendship/".count)
            
            switch subType {
            case "change-state":
                let changedState = try BSONDecoder().decode(ChangeFriendshipState.self, from: message.message.metadata)
                
                return try await contact.modifyMetadata(
                    ofType: FriendshipMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.theirState = changedState.newState
                    return .ignore
                }
            default:
                return .ignore
            }
        }
        
        switch (await contact.getOurState(), await contact.getTheirState()) {
        case (.blocked, _), (_, .blocked):
            return .ignore
        case (.undecided, _), (_, .undecided):
            if message.message.messageType == .magic {
                return ruleset.canIgnoreMagicPackets ? .ignore : nil
            } else {
                return ruleset.ignoreWhenUndecided ? .ignore : nil
            }
        case (.friend, .friend):
            return nil
        case (.notFriend, _), (_, .notFriend):
            return .ignore
        }
    }
    
    public func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction? { nil }
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document {
        let metadata = FriendshipMetadata(
            ourState: .undecided,
            theirState: .undecided
        )
        
        return try BSONEncoder().encode(metadata)
    }
    
    // Uninteresting events
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document{
        // We don't store any metadata in PrivateChat right now
        // Contact is used instead
        return [:]
    }

    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
    public func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws { }
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws { }
}

@available(macOS 12, iOS 15, *)
extension Contact {
    public func getOurState() async -> FriendshipStatus {
        await (try? self.model.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.ourState
        )) ?? .undecided
    }
    
    public func getTheirState() async -> FriendshipStatus {
        await (try? self.model.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.theirState
        )) ?? .undecided
    }
    
    public func isMutualFriendship() async -> Bool {
        await (try? self.model.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.mutualFriendship
        )) ?? false
    }
    
    public func isContactBlocked() async -> Bool {
        await (try? self.model.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.contactBlocked
        )) ?? false
    }
    
    public func block() async throws {
        try await changeOurState(to: .blocked)
    }
    
    public func befriend() async throws {
        try await changeOurState(to: .friend)
    }
    
    public func unfriend() async throws {
        try await changeOurState(to: .notFriend)
    }
    
    public func unblock() async throws {
        guard await getOurState() == .blocked else {
            return
        }
        
        let oldState = (try? await self.model.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.ourPreBlockedState
        )) ?? .undecided
        
        return try await changeOurState(to: oldState)
    }
    
    fileprivate func changeOurState(to newState: FriendshipStatus) async throws {
        try await self.modifyMetadata(
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
        }
        
        let message = try BSONEncoder().encode(
            ChangeFriendshipState(
                newState: newState,
                subject: self.username
            )
        )
        
        let internalChat = try await self.messenger.getInternalConversation()
        _ = try await internalChat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/friendship/change-state",
            text: "",
            metadata: message,
            preferredPushType: .none
        )
        
        let privateChat = try await self.messenger.createPrivateChat(with: self.username)
        _ = try await privateChat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/friendship/change-state",
            text: "",
            metadata: message,
            preferredPushType: .none
        )
    }
}
