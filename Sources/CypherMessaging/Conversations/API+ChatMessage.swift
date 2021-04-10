public struct AnyChatMessage {
    public let target: TargetConversation
    internal let messenger: CypherMessenger
    internal let chatMessage: DecryptedModel<ChatMessage>
    
    public var deliveryState: ChatMessage.DeliveryState {
        chatMessage.deliveryState
    }
    
    public func markAsRead() -> EventLoopFuture<Void> {
        if chatMessage.deliveryState == .read {
            return messenger.eventLoop.makeSucceededVoidFuture()
        }
        
        return messenger._markMessage(byId: chatMessage.id, as: .read).map { _ in }
    }
}
