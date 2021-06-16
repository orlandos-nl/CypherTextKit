import Foundation

@available(macOS 12, iOS 15, *)
public struct AnyChatMessage {
    public let target: TargetConversation
    public let messenger: CypherMessenger
    public let raw: DecryptedModel<ChatMessageModel>
    
    public func markAsRead() async throws {
        if raw.deliveryState == .read || sender == messenger.username {
            return
        }
        
        _ = try await messenger._markMessage(byId: raw.encrypted.id, as: .read)
    }
    
    public var text: String {
        raw.message.text
    }
    
    public var metadata: Document {
        raw.message.metadata
    }
    
    public var messageType: CypherMessageType {
        raw.message.messageType
    }
    
    public var messageSubtype: String? {
        raw.message.messageSubtype
    }
    
    public var sentDate: Date? {
        raw.message.sentDate
    }
    
    public var destructionTimer: TimeInterval? {
        raw.message.destructionTimer
    }
    
    public var sender: Username {
        raw.senderUser
    }
    
    public func destroy() async throws {
        try await messenger.cachedStore.removeChatMessage(raw.encrypted)
    }
}
