public struct AnyChatMessage {
    public let target: TargetConversation
    public var id: UUID { raw.id }
    internal let messenger: CypherMessenger
    internal let raw: DecryptedModel<ChatMessage>
    public var message: CypherMessage { raw.message }
    public var sendDate: Date { raw.props.sendDate }
    public var receiveDate: Date { raw.props.receiveDate }
    public var senderUser: Username { raw.props.senderUser }
    public var senderDeviceId: DeviceId { raw.props.senderDeviceId }
    
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
