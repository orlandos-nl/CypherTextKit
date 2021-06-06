import CypherMessaging

public protocol Plugin {
    static var pluginIdentifier: String { get }
    
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void>
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void>
    func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?>
    func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction?>
    func onMessageChange(_ message: AnyChatMessage)
    func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) -> EventLoopFuture<Document>
    func createContactMetadata(for username: Username, messenger: CypherMessenger) -> EventLoopFuture<Document>
    func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger)
    func onCreateConversation(_ conversation: AnyConversation)
    func onCreateChatMessage(_ conversation: AnyChatMessage)
    func onContactIdentityChange(username: Username, messenger: CypherMessenger)
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger)
    func onP2PClientClose(messenger: CypherMessenger)
}

extension Plugin {
    public var pluginIdentifier: String { Self.pluginIdentifier }
}

extension Contact {
    public func withMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) throws -> Result {
        let pluginStorage = self.metadata[plugin.pluginIdentifier] ?? Document()
        var metadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        let result = try run(&metadata)
        self.metadata[plugin.pluginIdentifier] = try BSONEncoder().encode(metadata)
        
        return result
    }
    
    public func modifyMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) -> EventLoopFuture<Result> {
        do {
            let result = try withMetadata(ofType: type, forPlugin: plugin, run: run)
            
            return self.save().map {
                result
            }
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
    }
}

extension AnyConversation {
    public func withMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) throws -> Result {
        let pluginStorage = self.conversation.metadata[plugin.pluginIdentifier] ?? Document()
        var metadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        let result = try run(&metadata)
        self.conversation.metadata[plugin.pluginIdentifier] = try BSONEncoder().encode(metadata)
        
        return result
    }
    
    public func modifyMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) -> EventLoopFuture<Result> {
        do {
            let result = try withMetadata(ofType: type, forPlugin: plugin, run: run)
            
            return self.save().map {
                result
            }
        } catch {
            return self.messenger.eventLoop.makeFailedFuture(error)
        }
    }
}

extension CypherMessenger {
    public func withCustomConfig<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: @escaping (C) throws -> Result
    ) -> EventLoopFuture<Result> {
        return readCustomConfig().flatMapThrowing { customConfig in
            let pluginStorage = customConfig[plugin.pluginIdentifier] ?? Document()
            let metadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
            return try run(metadata)
        }
    }
    
    public func modifyCustomConfig<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: @escaping (inout C) throws -> Result
    ) -> EventLoopFuture<Result> {
        return readCustomConfig().flatMap { customConfig in
            do {
                var customConfig = customConfig
                let pluginStorage = customConfig[plugin.pluginIdentifier] ?? Document()
                var metadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
                let result = try run(&metadata)
                customConfig[plugin.pluginIdentifier] = try BSONEncoder().encode(metadata)
                return self.writeCustomConfig(customConfig).map {
                    return result
                }
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        }
    }
}
