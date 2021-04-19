import NIO
import CypherProtocol
import CypherTransport

public struct DeviceReference {
    public let username: Username
    public let deviceId: DeviceId
}

public struct ReceivedMessageContext {
    public let sender: DeviceReference
    public let messenger: CypherMessenger
    public var message: CypherMessage
    public let conversation: TargetConversation.Resolved
}

public struct SentMessageContext {
    public let recipients: Set<Username>
    public let messenger: CypherMessenger
    public var message: CypherMessage
    public let conversation: TargetConversation.Resolved
}

public struct SendMessageAction {
    internal enum _Action {
        case send, saveAndSend
    }
    
    internal let raw: _Action
    
    public static let send = SendMessageAction(raw: .send)
    public static let saveAndSend = SendMessageAction(raw: .saveAndSend)
}

public struct ProcessMessageAction {
    internal enum _Action {
        case ignore, save
    }
    
    internal let raw: _Action
    
    public static let ignore = ProcessMessageAction(raw: .ignore)
    public static let save = ProcessMessageAction(raw: .save)
}

public protocol CypherMessengerEventHandler {
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void>
    func receiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction>
    func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction>
    func privateChatMetadata(withUser otherUser: Username) -> EventLoopFuture<Document>
    func onCreateConversation(_ conversation: Conversation) -> EventLoopFuture<Void>
    func onCreateChatMessage(_ conversation: AnyChatMessage) -> EventLoopFuture<Void>
}
