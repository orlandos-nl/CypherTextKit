import NIO
import CypherProtocol

public struct DeviceReference {
    public let username: Username
    public let deviceId: DeviceId
}

@available(macOS 10.15, iOS 13, *)
public struct ReceivedMessageContext {
    public let sender: DeviceReference
    public let messenger: CypherMessenger
    public var message: SingleCypherMessage
    public let conversation: TargetConversation.Resolved
}

@available(macOS 10.15, iOS 13, *)
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

// TODO: Make this into a concrete type, so more events can be supported
@available(macOS 10.15, iOS 13, *)
public protocol CypherMessengerEventHandler {
    @MainActor func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws
    @MainActor func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws
    @MainActor func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction
    @MainActor func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction
    @MainActor func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document
    @MainActor func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document
    @MainActor func onMessageChange(_ message: AnyChatMessage)
    @MainActor func onCreateContact(_ contact: Contact, messenger: CypherMessenger)
    @MainActor func onUpdateContact(_ contact: Contact)
    @MainActor func onCreateConversation(_ conversation: AnyConversation)
    @MainActor func onUpdateConversation(_ conversation: AnyConversation)
    @MainActor func onCreateChatMessage(_ conversation: AnyChatMessage)
    @MainActor func onContactIdentityChange(username: Username, messenger: CypherMessenger)
    @MainActor func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger)
    @MainActor func onP2PClientClose(messenger: CypherMessenger)
    @MainActor func onRemoveContact(_ contact: Contact)
    @MainActor func onRemoveChatMessage(_ message: AnyChatMessage)
    @MainActor func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) async throws
}
