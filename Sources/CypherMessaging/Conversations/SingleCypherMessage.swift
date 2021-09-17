import BSON
import CypherProtocol
import Foundation

public enum PushType: String, Codable {
    case none, call, message, contactRequest = "contactrequest", cancelCall = "cancelcall"
}

public enum CypherMessageType: String, Codable {
    case text, media, magic
}

@available(macOS 12, iOS 15, *)
public enum TargetConversation {
    case currentUser
    case otherUser(Username)
    case groupChat(GroupChatId)
    
    public func resolve(
        in messenger: CypherMessenger
    ) async throws -> TargetConversation.Resolved {
        switch self {
        case .currentUser:
            return try await .internalChat(messenger.getInternalConversation())
        case .otherUser(let username):
            if let chat = try await messenger.getPrivateChat(with: username) {
                return .privateChat(chat)
            }
            
            throw CypherSDKError.unknownChat
        case .groupChat(let groupId):
            if let chat = try await messenger.getGroupChat(byId: groupId) {
                return .groupChat(chat)
            }
            
            throw CypherSDKError.unknownGroup
        }
    }
    
    public enum Resolved: AnyConversation, Identifiable {
        case privateChat(PrivateChat)
        case groupChat(GroupChat)
        case internalChat(InternalConversation)
        
        init?(conversation: DecryptedModel<ConversationModel>, messenger: CypherMessenger) async {
            let members = conversation.members
            let username = messenger.username
            guard members.contains(username) else {
                return nil
            }
            
            let metadata = conversation.metadata
            switch members.count {
            case ..<0:
                return nil
            case 1:
                self = .internalChat(InternalConversation(conversation: conversation, messenger: messenger))
            case 2 where metadata["_type"] as? String != "group":
                self = .privateChat(PrivateChat(conversation: conversation, messenger: messenger))
            default:
                if metadata["_type"] as? String == "group" {
                    do {
                        let groupMetadata = try BSONDecoder().decode(
                            GroupMetadata.self,
                            from: metadata
                        )
                        
                        self = .groupChat(GroupChat(conversation: conversation, messenger: messenger, metadata: groupMetadata))
                    } catch {
                        return nil
                    }
                } else {
                    return nil
                }
            }
        }
        
        public var conversation: DecryptedModel<ConversationModel> {
            switch self {
            case .privateChat(let chat):
                return chat.conversation
            case .groupChat(let chat):
                return chat.conversation
            case .internalChat(let chat):
                return chat.conversation
            }
        }
        
        public var messenger: CypherMessenger {
            switch self {
            case .privateChat(let chat):
                return chat.messenger
            case .groupChat(let chat):
                return chat.messenger
            case .internalChat(let chat):
                return chat.messenger
            }
        }
        
        public func getTarget() async -> TargetConversation {
            switch self {
            case .privateChat(let chat):
                return chat.getTarget()
            case .groupChat(let chat):
                return await chat.getTarget()
            case .internalChat(let chat):
                return await chat.getTarget()
            }
        }
        
        public func resolveTarget() async -> TargetConversation.Resolved {
            self
        }
        
        public var cache: Cache {
            switch self {
            case .privateChat(let chat):
                return chat.cache
            case .groupChat(let chat):
                return chat.cache
            case .internalChat(let chat):
                return chat.cache
            }
        }
        
        public var id: UUID {
            conversation.id
        }
    }
}

@available(macOS 12, iOS 15, *)
public struct ConversationTarget: Codable {
    // Only the fields specified here are encoded
    private enum CodingKeys: String, CodingKey {
        case groupChatId = "a"
        case recipient = "b"
    }
    
    private let groupChatId: GroupChatId?
    private let recipient: Username?
    
    init(
        groupChatId: GroupChatId?,
        recipient: Username?
    ) {
        self.groupChatId = groupChatId
        self.recipient = recipient
    }
    
    public var reference: TargetConversation {
        if let groupChatId = self.groupChatId {
            return .groupChat(groupChatId)
        } else if let recipient = self.recipient {
            return .otherUser(recipient)
        } else {
            return .currentUser
        }
    }
}

@available(macOS 12, iOS 15, *)
public struct SingleCypherMessage: Codable {
    // Only the fields specified here are encoded
    private enum CodingKeys: String, CodingKey {
        case messageType = "a"
        case messageSubtype = "b"
        case text = "c"
        case metadata = "d"
        case destructionTimer = "e"
        case sentDate = "f"
        case preferredPushType = "g"
        case order = "h"
        case _target = "i"
    }
    
    public var messageType: CypherMessageType
    public var messageSubtype: String?
    public var text: String
    public var metadata: Document
    public let destructionTimer: TimeInterval?
    public let sentDate: Date?
    private let _target: ConversationTarget
    let preferredPushType: PushType?
    public private(set) var order: Int
    
    public var target: TargetConversation {
        _target.reference
    }
    
    init(
        messageType: CypherMessageType,
        messageSubtype: String? = nil,
        text: String,
        metadata: Document,
        destructionTimer: TimeInterval? = nil,
        sentDate: Date? = Date(),
        preferredPushType: PushType? = nil,
        order: Int,
        target: TargetConversation
    ) {
        self.messageType = messageType
        self.messageSubtype = messageSubtype
        self.text = text
        self.metadata = metadata
        self.destructionTimer = destructionTimer
        self.sentDate = sentDate
        self.preferredPushType = preferredPushType
        self.order = order
        
        switch target {
        case .currentUser:
            self._target = ConversationTarget(groupChatId: nil, recipient: nil)
        case .groupChat(let group):
            self._target = ConversationTarget(groupChatId: group, recipient: nil)
        case .otherUser(let user):
            self._target = ConversationTarget(groupChatId: nil, recipient: user)
        }
    }
}
