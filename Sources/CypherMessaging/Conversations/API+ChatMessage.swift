@available(macOS 12, iOS 15, *)
public struct AnyChatMessage {
    public let target: TargetConversation
    public var id: UUID { raw.id }
    public let messenger: CypherMessenger
    internal let raw: DecryptedModel<ChatMessageModel>
    public var message: SingleCypherMessage { raw.message }
    public var sendDate: Date { raw.props.sendDate }
    public var receiveDate: Date { raw.props.receiveDate }
    public var senderUser: Username { raw.props.senderUser }
    public var senderDeviceId: DeviceId { raw.props.senderDeviceId }
    public var remoteId: String { raw.encrypted.remoteId }
    
    public var deliveryState: ChatMessageModel.DeliveryState {
        raw.deliveryState
    }
    
    public func markAsRead() async throws {
        if raw.deliveryState == .read {
            return
        }
        
        return try await messenger._markMessage(byId: raw.id, as: .read).map { _ in }.get()
    }
    
    public func destroy() async throws {
        try await messenger.cachedStore.removeChatMessage(raw.encrypted).get()
    }
}
