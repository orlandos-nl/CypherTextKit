import NIO

@available(macOS 10.15, iOS 13, *)
public struct SpoofCypherEventHandler: CypherMessengerEventHandler {
    public init() {}
    
    public func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws {}
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {
        try await messenger.addDevice(config)
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction {
        message.message.messageType == .magic ? .ignore : .save
    }
    
    public func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction {
        message.message.messageType == .magic ? .send : .saveAndSend
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document {
        [:]
    }
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document {
        [:]
    }
    
    public func onUpdateContact(_ contact: Contact) {}
    
    public func onUpdateConversation(_ conversation: AnyConversation) {}
    
    public func onCreateConversation(_ conversation: AnyConversation) {}
    
    public func onCreateChatMessage(_ conversation: AnyChatMessage) {}
    
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {}
    
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) {}
    
    public func onMessageChange(_ message: AnyChatMessage) {}
    
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {}
    
    public func onP2PClientClose(messenger: CypherMessenger) {}
    
    public func onRemoveContact(_ contact: Contact) {}
    
    public func onRemoveChatMessage(_ message: AnyChatMessage) {}
    public func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) {}
    public func onOtherUserDeviceRegistery(username: Username, deviceId: DeviceId, messenger: CypherMessenger) { }
    public func onCustomConfigChange() {}
}
