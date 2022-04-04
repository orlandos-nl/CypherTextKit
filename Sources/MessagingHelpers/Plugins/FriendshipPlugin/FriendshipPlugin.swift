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

@available(macOS 10.15, iOS 13, *)
public struct FriendshipPlugin: Plugin {
    public static let pluginIdentifier = "@/contacts/friendship"
    public let ruleset: FriendshipRuleset
    
    public init(ruleset: FriendshipRuleset) {
        self.ruleset = ruleset
    }
    
    @MainActor public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        let senderUsername = message.sender.username
        let target = await message.conversation.getTarget()
        let username = message.messenger.username
        
        if case .groupChat = target {
            if ruleset.blockAffectsGroupChats, senderUsername != username {
                let contact = try await message.messenger.createContact(byUsername: senderUsername)
                return contact.isBlocked ? .ignore : nil
            }
            
            return nil
        }
        
        if senderUsername == username {
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
            case "query":
                let changedState = try BSONEncoder().encode(
                    ChangeFriendshipState(
                        newState: contact.ourFriendshipState,
                        subject: contact.username
                    )
                )
                
                try await message.conversation.sendRawMessage(
                    type: .magic,
                    messageSubtype: "@/contacts/friendship/change-state",
                    text: "",
                    metadata: changedState,
                    preferredPushType: .none
                )
                return .ignore
            default:
                return .ignore
            }
        }
        
        switch (contact.ourFriendshipState, contact.theirFriendshipState) {
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
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document {
        let metadata = FriendshipMetadata(
            ourState: .undecided,
            theirState: .undecided
        )
        
        return try BSONEncoder().encode(metadata)
    }
}

@available(macOS 10.15, iOS 13, *)
extension Contact {
    @MainActor public var ourFriendshipState: FriendshipStatus {
        (try? self.model.getProp(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.ourState
        )) ?? .undecided
    }
    
    @MainActor public var theirFriendshipState: FriendshipStatus {
        (try? self.model.getProp(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.theirState
        )) ?? .undecided
    }
    
    @MainActor public var isMutualFriendship: Bool {
        (try? self.model.getProp(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.mutualFriendship
        )) ?? false
    }
    
    @MainActor public var isBlocked: Bool {
        (try? self.model.getProp(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.contactBlocked
        )) ?? false
    }
    
    @MainActor public func block() async throws {
        try await changeOurState(to: .blocked)
    }
    
    @MainActor public func befriend() async throws {
        try await changeOurState(to: .friend)
    }
    
    @MainActor public func unfriend() async throws {
        try await changeOurState(to: .notFriend)
    }
    
    @MainActor public func query() async throws {
        let privateChat = try await self.messenger.createPrivateChat(with: self.username)
        try await privateChat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/friendship/query",
            text: "",
            preferredPushType: .none
        )
    }
    
    @MainActor public func unblock() async throws {
        guard ourFriendshipState == .blocked else {
            return
        }
        
        let oldState = (try? await self.model.withMetadata(
            ofType: FriendshipMetadata.self,
            forPlugin: FriendshipPlugin.self,
            run: \.ourPreBlockedState
        )) ?? .undecided
        
        return try await changeOurState(to: oldState)
    }
    
    @MainActor fileprivate func changeOurState(to newState: FriendshipStatus) async throws {
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
        try await internalChat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/friendship/change-state",
            text: "",
            metadata: message,
            preferredPushType: .none
        )
        
        let privateChat = try await self.messenger.createPrivateChat(with: self.username)
        try await privateChat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/friendship/change-state",
            text: "",
            metadata: message,
            preferredPushType: .none
        )
    }
}
