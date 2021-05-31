import BSON
import CypherProtocol
import Foundation

public enum PushType: String, Codable {
    case none, call, message, contactRequest = "contactrequest"
}

public enum CypherMessageType: String, Codable {
    case text, media, magic
}

public enum TargetConversation {
    case currentUser
    case otherUser(Username)
    case groupChat(GroupChatId)
    
    public enum Resolved {
        case privateChat(PrivateChat)
        case groupChat(GroupChat)
        case internalChat(InternalConversation)
    }
}

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
