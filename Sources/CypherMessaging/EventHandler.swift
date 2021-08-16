import NIO
import CypherProtocol

public struct DeviceReference {
    public let username: Username
    public let deviceId: DeviceId
}

@available(macOS 12, iOS 15, *)
public struct ReceivedMessageContext {
    public let sender: DeviceReference
    public let messenger: CypherMessenger
    public var message: SingleCypherMessage
    public let conversation: TargetConversation.Resolved
}

@available(macOS 12, iOS 15, *)
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

@available(macOS 12, iOS 15, *)
public protocol CypherMessengerEventHandler {
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws
    func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction
    func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction
    func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document
    func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document
    func onMessageChange(_ message: AnyChatMessage)
    func onCreateContact(_ contact: Contact, messenger: CypherMessenger)
    func onUpdateContact(_ contact: Contact)
    func onCreateConversation(_ conversation: AnyConversation)
    func onUpdateConversation(_ conversation: AnyConversation)
    func onCreateChatMessage(_ conversation: AnyChatMessage)
    func onContactIdentityChange(username: Username, messenger: CypherMessenger)
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger)
    func onP2PClientClose(messenger: CypherMessenger)
    func onRemoveContact(_ contact: Contact)
    func onRemoveChatMessage(_ message: AnyChatMessage)
    func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) async throws
}
