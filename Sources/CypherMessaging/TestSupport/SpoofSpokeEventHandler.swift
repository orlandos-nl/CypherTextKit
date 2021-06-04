import NIO

public struct SpoofCypherEventHandler: CypherMessengerEventHandler {
    public let eventLoop: EventLoop
    
    public init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.addDevice(config)
    }
    
    public func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction> {
        eventLoop.makeSucceededFuture(.saveAndSend)
    }
    
    public func receiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction> {
        eventLoop.makeSucceededFuture(.save)
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username) -> EventLoopFuture<Document> {
        eventLoop.makeSucceededFuture([:])
    }
    
    public func createContactMetadata(for username: Username) -> EventLoopFuture<Document> {
        eventLoop.makeSucceededFuture([:])
    }
    
    public func onCreateConversation(_ conversation: AnyConversation) {}
    
    public func onCreateChatMessage(_ conversation: AnyChatMessage) {}
    
    public func onCreateContact(_ contact: DecryptedModel<Contact>, messenger: CypherMessenger) {}
    
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) {}
    
    public func onMessageChange(_ message: AnyChatMessage) {}
    
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {}
    
    public func onP2PClientClose(messenger: CypherMessenger) {}
    
    public func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        eventLoop.makeSucceededVoidFuture()
    }
}
