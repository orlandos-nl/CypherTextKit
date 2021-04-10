import NIO
import CypherTransport

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
    
    public func privateChatMetadata(withUser otherUser: Username) -> EventLoopFuture<Document> {
        eventLoop.makeSucceededFuture([:])
    }
}
