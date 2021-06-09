@available(macOS 12, iOS 15, *)
public struct AnyChatMessage {
    public let target: TargetConversation
    public let messenger: CypherMessenger
    public let raw: DecryptedModel<ChatMessageModel>
    
    public func markAsRead() async throws {
        if await raw.deliveryState == .read {
            return
        }
        
        _ = try await messenger._markMessage(byId: raw.id, as: .read)
    }
    
    public func destroy() async throws {
        try await messenger.cachedStore.removeChatMessage(raw.encrypted)
    }
}
