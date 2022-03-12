import Foundation

@available(macOS 10.15, iOS 13, *)
public struct AnyChatMessage: Sendable {
    public let target: TargetConversation
    public let messenger: CypherMessenger
    public let raw: DecryptedModel<ChatMessageModel>
    
    @MainActor public func markAsRead() async throws {
        if raw.deliveryState == .read || sender == messenger.username {
            return
        }
        
        try await messenger._markMessage(byId: raw.encrypted.id, as: .read)
    }
    
    @MainActor public var text: String {
        raw.message.text
    }
    
    @MainActor public var metadata: Document {
        raw.message.metadata
    }
    
    @MainActor public var messageType: CypherMessageType {
        raw.message.messageType
    }
    
    @MainActor public var messageSubtype: String? {
        raw.message.messageSubtype
    }
    
    @MainActor public var sentDate: Date? {
        raw.message.sentDate
    }
    
    @MainActor public var destructionTimer: TimeInterval? {
        raw.message.destructionTimer
    }
    
    @MainActor public var sender: Username {
        raw.senderUser
    }
    
    @MainActor public func remove() async throws {
        try await messenger.cachedStore.removeChatMessage(raw.encrypted)
        messenger.eventHandler.onRemoveChatMessage(self)
    }
}
