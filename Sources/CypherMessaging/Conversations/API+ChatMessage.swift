public struct AnyChatMessage {
    public let target: TargetConversation
    internal let messenger: CypherMessenger
    public let raw: DecryptedModel<ChatMessage>
    
    public var deliveryState: ChatMessage.DeliveryState {
        raw.deliveryState
    }
    
    public func markAsRead() -> EventLoopFuture<Void> {
        if raw.deliveryState == .read {
            return messenger.eventLoop.makeSucceededVoidFuture()
        }
        
        return messenger._markMessage(byId: raw.id, as: .read).map { _ in }
    }
}
