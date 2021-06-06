import CypherMessaging
import NIO

fileprivate struct ChatActivityMetadata: Codable {
    var lastActivity: Date?
}

// TODO: Use synchronisation framework for own devices
// TODO: Select contacts to share the profile changes with
// TODO: Broadcast to a user that doesn't have a private chat
public struct ChatActivityPlugin: Plugin {
    public static let pluginIdentifier = "@/chats/activity"
    
    public init() {}
    
    public func onRekey(
        withUser username: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?> {
        if message.message.messageType == .magic {
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        return message.conversation.modifyMetadata(
            ofType: ChatActivityMetadata.self,
            forPlugin: Self.self
        ) { metadata in
            metadata.lastActivity = Date()
            return nil
        }
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) -> EventLoopFuture<SendMessageAction?> {
        if message.message.messageType == .magic {
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        return message.conversation.modifyMetadata(
            ofType: ChatActivityMetadata.self,
            forPlugin: Self.self
        ) { metadata in
            metadata.lastActivity = Date()
            return nil
        }
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
}

extension AnyConversation {
    public var lastActivity: Date? {
        try? self.withMetadata(
            ofType: ChatActivityMetadata.self,
            forPlugin: ChatActivityPlugin.self
        ) { metadata in
            metadata.lastActivity
        }
    }
}
