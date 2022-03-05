import Foundation

@available(macOS 10.15, iOS 13, *)
public struct AnyChatMessage {
    public let target: TargetConversation
    public let messenger: CypherMessenger
    public let raw: DecryptedModel<ChatMessageModel>
    
    @CryptoActor public func markAsRead() async throws {
        if raw.deliveryState == .read || sender == messenger.username {
            return
        }
        
        _ = try await messenger._markMessage(byId: raw.encrypted.id, as: .read)
    }
    
    @CryptoActor public var text: String {
        raw.message.text
    }
    
    @CryptoActor public var metadata: Document {
        raw.message.metadata
    }
    
    @CryptoActor public var messageType: CypherMessageType {
        raw.message.messageType
    }
    
    @CryptoActor public var messageSubtype: String? {
        raw.message.messageSubtype
    }
    
    @CryptoActor public var sentDate: Date? {
        raw.message.sentDate
    }
    
    @CryptoActor public var destructionTimer: TimeInterval? {
        raw.message.destructionTimer
    }
    
    @CryptoActor public var sender: Username {
        raw.senderUser
    }
    
    @CryptoActor public func remove() async throws {
        try await messenger.cachedStore.removeChatMessage(raw.encrypted)
        messenger.eventHandler.onRemoveChatMessage(self)
    }
}
