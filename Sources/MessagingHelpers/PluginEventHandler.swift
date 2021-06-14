import CypherMessaging

@available(macOS 12, iOS 15, *)
public struct PluginEventHandler: CypherMessengerEventHandler {
    private var plugins: [Plugin]
    
    public init(plugins: [Plugin]) {
        self.plugins = plugins
    }
    
    public func onRekey(
        withUser username: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) async throws {
        for plugin in plugins {
            try await plugin.onRekey(withUser: username, deviceId: deviceId, messenger: messenger)
        }
    }
    
    public func onDeviceRegisteryRequest(
        _ config: UserDeviceConfig,
        messenger: CypherMessenger
    ) async throws {
        for plugin in plugins {
            try await plugin.onDeviceRegisteryRequest(config, messenger: messenger)
        }
    }
    
    public func onReceiveMessage(
        _ message: ReceivedMessageContext
    ) async throws -> ProcessMessageAction {
        for plugin in plugins {
            if let result = try await plugin.onReceiveMessage(message) {
                return result
            }
        }
        
        switch message.message.messageType {
        case .magic:
            return .ignore
        case .text, .media:
            return .save
        }
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) async throws -> SendMessageAction {
        for plugin in plugins {
            if let result = try await plugin.onSendMessage(message) {
                return result
            }
        }
        
        switch message.message.messageType {
        case .magic:
            return .send
        case .text, .media:
            return .saveAndSend
        }
    }
    
    public func onMessageChange(_ message: AnyChatMessage) {
        for plugin in plugins {
            plugin.onMessageChange(message)
        }
    }
    
    public func createPrivateChatMetadata(
        withUser otherUser: Username,
        messenger: CypherMessenger
    ) async throws -> Document {
        let metadata = plugins.map { plugin -> EventLoopFuture<(String, Document)> in
            messenger.eventLoop.executeAsync {
                let document = try await plugin.createPrivateChatMetadata(withUser: otherUser, messenger: messenger)
                return (plugin.pluginIdentifier, document)
            }
        }
        
        return try await EventLoopFuture.whenAllSucceed(metadata, on: messenger.eventLoop).map { results in
            var document = Document()
            
            for (key, value) in results {
                document[key] = value
            }
            
            return document
        }.get()
    }
    
    public func createContactMetadata(
        for otherUser: Username,
        messenger: CypherMessenger
    ) async throws -> Document {
        let metadata = plugins.map { plugin -> EventLoopFuture<(String, Document)> in
            messenger.eventLoop.executeAsync {
                let document = try await plugin.createContactMetadata(for: otherUser, messenger: messenger)
                return (plugin.pluginIdentifier, document)
            }
        }
        
        return try await EventLoopFuture.whenAllSucceed(metadata, on: messenger.eventLoop).map { results in
            var document = Document()
            
            for (key, value) in results {
                document[key] = value
            }
            
            return document
        }.get()
    }
    
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {
        for plugin in plugins {
            plugin.onCreateContact(contact, messenger: messenger)
        }
    }
    
    public func onCreateConversation(_ conversation: AnyConversation) {
        for plugin in plugins {
            plugin.onCreateConversation(conversation)
        }
    }
    
    public func onCreateChatMessage(_ conversation: AnyChatMessage) {
        for plugin in plugins {
            plugin.onCreateChatMessage(conversation)
        }
    }
    
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) {
        for plugin in plugins {
            plugin.onContactIdentityChange(username: username, messenger: messenger)
        }
    }
    
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {
        for plugin in plugins {
            plugin.onP2PClientOpen(client, messenger: messenger)
        }
    }
    
    public func onP2PClientClose(messenger: CypherMessenger) {
        for plugin in plugins {
            plugin.onP2PClientClose(messenger: messenger)
        }
    }
}
