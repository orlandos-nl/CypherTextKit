import NIO
import CypherProtocol

public struct DeviceReference {
    public let username: Username
    public let deviceId: DeviceId
}

public struct ReceivedMessageContext {
    public let sender: DeviceReference
    public let messenger: CypherMessenger
    public var message: SingleCypherMessage
    public let conversation: TargetConversation.Resolved
}

public struct SentMessageContext {
    public let recipients: Set<Username>
    public let messenger: CypherMessenger
    public var message: SingleCypherMessage
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
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void>
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void>
    func receiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction>
    func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction>
    func onMessageChange(_ message: AnyChatMessage)
    func createPrivateChatMetadata(withUser otherUser: Username) -> EventLoopFuture<Document>
    func createContactMetadata(for username: Username) -> EventLoopFuture<Document>
    func onCreateContact(_ contact: DecryptedModel<Contact>, messenger: CypherMessenger)
    func onCreateConversation(_ conversation: AnyConversation)
    func onCreateChatMessage(_ conversation: AnyChatMessage)
    func onContactIdentityChange(username: Username, messenger: CypherMessenger)
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger)
    func onP2PClientClose(messenger: CypherMessenger)
}
