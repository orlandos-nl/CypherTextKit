import CypherMessaging
import NIO

fileprivate struct ChatActivityMetadata: Codable {
    var lastActivity: Date?
}

// TODO: Use synchronisation framework for own devices
// TODO: Select contacts to share the profile changes with
// TODO: Broadcast to a user that doesn't have a private chat
@available(macOS 10.15, iOS 13, *)
public struct ChatActivityPlugin: Plugin {
    public static let pluginIdentifier = "@/chats/activity"
    
    public init() {}
    
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
}

@available(macOS 10.15, iOS 13, *)
extension AnyConversation {
    @CryptoActor public var lastActivity: Date? {
        try? self.conversation.getProp(
            ofType: ChatActivityMetadata.self,
            forPlugin: ChatActivityPlugin.self,
            run: \.lastActivity
        )
    }
}
