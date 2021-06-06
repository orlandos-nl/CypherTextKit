import CypherMessaging

public struct PluginEventHandler: CypherMessengerEventHandler {
    private var plugins: [Plugin]
    
    public init(plugins: [Plugin]) {
        self.plugins = plugins
    }
    
    public func onRekey(
        withUser: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onDeviceRegisteryRequest(
        _ config: UserDeviceConfig,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Void> {
        let done = plugins.map { plugin in
            plugin.onDeviceRegisteryRequest(config, messenger: messenger)
        }
        
        return EventLoopFuture.andAllSucceed(done, on: messenger.eventLoop)
    }
    
    public func onReceiveMessage(
        _ message: ReceivedMessageContext
    ) -> EventLoopFuture<ProcessMessageAction> {
        var plugins = self.plugins.makeIterator()
        
        func next() -> EventLoopFuture<ProcessMessageAction> {
            guard let plugin = plugins.next() else {
                return message.messenger.eventLoop.makeSucceededFuture(
                    message.message.messageType == .magic ? .ignore : .save
                )
            }
            
            return plugin.onReceiveMessage(message).flatMap { result in
                if let result = result {
                    return message.messenger.eventLoop.makeSucceededFuture(result)
                }
                
                return next()
            }
        }
        
        return next()
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) -> EventLoopFuture<SendMessageAction> {
        var plugins = self.plugins.makeIterator()
        
        func next() -> EventLoopFuture<SendMessageAction> {
            guard let plugin = plugins.next() else {
                return message.messenger.eventLoop.makeSucceededFuture(
                    message.message.messageType == .magic ? .send : .saveAndSend
                )
            }
            
            return plugin.onSendMessage(message).flatMap { result in
                if let result = result {
                    return message.messenger.eventLoop.makeSucceededFuture(result)
                }
                
                return next()
            }
        }
        
        return next()
    }
    
    public func onMessageChange(_ message: AnyChatMessage) {
        for plugin in plugins {
            plugin.onMessageChange(message)
        }
    }
    
    public func createPrivateChatMetadata(
        withUser otherUser: Username,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Document> {
        let metadata = plugins.map { plugin -> EventLoopFuture<(String, Document)> in
            plugin.createPrivateChatMetadata(withUser: otherUser, messenger: messenger).map { document in
                return (plugin.pluginIdentifier, document)
            }
        }
        
        return EventLoopFuture.whenAllSucceed(metadata, on: messenger.eventLoop).map { results in
            var document = Document()
            
            for (key, value) in results {
                document[key] = value
            }
            
            return document
        }
    }
    
    public func createContactMetadata(
        for otherUser: Username,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Document> {
        let metadata = plugins.map { plugin -> EventLoopFuture<(String, Document)> in
            plugin.createContactMetadata(for: otherUser, messenger: messenger).map { document in
                return (plugin.pluginIdentifier, document)
            }
        }
        
        return EventLoopFuture.whenAllSucceed(metadata, on: messenger.eventLoop).map { results in
            var document = Document()
            
            for (key, value) in results {
                document[key] = value
            }
            
            return document
        }
    }
    
    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) {
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
