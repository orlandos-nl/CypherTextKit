import CypherMessaging
import NIO

fileprivate struct ChatActivityMetadata: Codable {
    var lastActivity: Date?
}

// TODO: Use synchronisation framework for own devices
// TODO: Select contacts to share the profile changes with
// TODO: Broadcast to a user that doesn't have a private chat
@available(macOS 12, iOS 15, *)
public struct ChatActivityPlugin: Plugin {
    public static let pluginIdentifier = "@/chats/activity"
    
    public init() {}
    
    public func onRekey(
        withUser username: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) async throws {}
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {}
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        switch message.message.messageType {
        case .magic:
            return nil
        case .text, .media:
            return try await message.conversation.modifyMetadata(
                ofType: ChatActivityMetadata.self,
                forPlugin: Self.self
            ) { metadata in
                metadata.lastActivity = Date()
                return nil
            }
        }
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) async throws -> SendMessageAction? {
        switch message.message.messageType {
        case .magic:
            return nil
        case .text, .media:
            return try await message.conversation.modifyMetadata(
                ofType: ChatActivityMetadata.self,
                forPlugin: Self.self
            ) { metadata in
                metadata.lastActivity = Date()
                return nil
            }
        }
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
}

@available(macOS 12, iOS 15, *)
extension AnyConversation {
    public var lastActivity: Date? {
        try? self.conversation.getProp(
            ofType: ChatActivityMetadata.self,
            forPlugin: ChatActivityPlugin.self,
            run: \.lastActivity
        )
    }
}
