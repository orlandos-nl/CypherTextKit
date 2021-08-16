import CypherMessaging

@available(macOS 12, iOS 15, *)
public protocol Plugin {
    static var pluginIdentifier: String { get }
    
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws
    func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction?
    func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction?
    func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document
    func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document
    func onMessageChange(_ message: AnyChatMessage)
    func onConversationChange(_ conversation: AnyConversation)
    func onContactChange(_ contact: Contact)
    func onCreateContact(_ contact: Contact, messenger: CypherMessenger)
    func onCreateConversation(_ conversation: AnyConversation)
    func onCreateChatMessage(_ conversation: AnyChatMessage)
    func onContactIdentityChange(username: Username, messenger: CypherMessenger)
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger)
    func onP2PClientClose(messenger: CypherMessenger)
    func onRemoveContact(_ contact: Contact)
    func onRemoveChatMessage(_ message: AnyChatMessage)
    func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) async throws
}

extension Plugin {
    public func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws {}
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {}
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? { nil }
    public func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction? { nil }
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    public func onMessageChange(_ message: AnyChatMessage) {}
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {}
    public func onConversationChange(_ conversation: AnyConversation) {}
    public func onCreateConversation(_ conversation: AnyConversation) {}
    public func onCreateChatMessage(_ conversation: AnyChatMessage) {}
    public func onContactChange(_ contact: Contact) {}
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) {}
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {}
    public func onP2PClientClose(messenger: CypherMessenger) {}
    public func onRemoveContact(_ contact: Contact) {}
    public func onRemoveChatMessage(_ message: AnyChatMessage) {}
    public func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) async throws {}
}

@available(macOS 12, iOS 15, *)
extension Plugin {
    public var pluginIdentifier: String { Self.pluginIdentifier }
}

@available(macOS 12, iOS 15, *)
extension DecryptedModel where M == ContactModel {
    public func getProp<P: Plugin, C: Codable, Result>(
        fromMetadata type: C.Type,
        forPlugin plugin: P.Type,
        run: (C) throws -> Result
    ) throws -> Result {
        let pluginStorage = metadata[plugin.pluginIdentifier] ?? Document()
        let pluginMetadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        return try run(pluginMetadata)
    }
    
    public func withMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) async throws -> Result {
        var metadata = self.metadata
        let pluginStorage = metadata[plugin.pluginIdentifier] ?? Document()
        var pluginMetadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        let result = try run(&pluginMetadata)
        metadata[plugin.pluginIdentifier] = try BSONEncoder().encode(pluginMetadata)
        try await self.setProp(at: \.metadata, to: metadata)
        
        return result
    }
}

extension Contact {
    public func modifyMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) async throws -> Result {
        let result = try await model.withMetadata(ofType: type, forPlugin: plugin, run: run)
        
        try await self.save()
        return result
    }
}

@available(macOS 12, iOS 15, *)
extension DecryptedModel where M.SecureProps: MetadataProps {
    public func getProp<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (C) throws -> Result
    ) throws -> Result {
        let pluginStorage = props.metadata[plugin.pluginIdentifier] ?? Document()
        let pluginMetadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        return try run(pluginMetadata)
    }
    
    public func withMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) async throws -> Result {
        var metadata = self.props.metadata
        let pluginStorage = metadata[plugin.pluginIdentifier] ?? Document()
        var pluginMetadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        let result = try run(&pluginMetadata)
        metadata[plugin.pluginIdentifier] = try BSONEncoder().encode(pluginMetadata)
        try await self.setProp(at: \.metadata, to: metadata)
        
        return result
    }
}

extension AnyConversation {
    public func modifyMetadata<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: (inout C) throws -> Result
    ) async throws -> Result {
        let result = try await conversation.withMetadata(ofType: type, forPlugin: plugin, run: run)
        try await self.save()
        return result
    }
}

@available(macOS 12, iOS 15, *)
extension CypherMessenger {
    public func withCustomConfig<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: @escaping (C) async throws -> Result
    ) async throws -> Result {
        let customConfig = try await readCustomConfig()
        let pluginStorage = customConfig[plugin.pluginIdentifier] ?? Document()
        let metadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        return try await run(metadata)
    }
    
    public func modifyCustomConfig<P: Plugin, C: Codable, Result>(
        ofType type: C.Type,
        forPlugin plugin: P.Type,
        run: @escaping (inout C) async throws -> Result
    ) async throws -> Result {
        var customConfig = try await readCustomConfig()
        let pluginStorage = customConfig[plugin.pluginIdentifier] ?? Document()
        var metadata = try BSONDecoder().decode(type, fromPrimitive: pluginStorage)
        let result = try await run(&metadata)
        customConfig[plugin.pluginIdentifier] = try BSONEncoder().encode(metadata)
        try await self.writeCustomConfig(customConfig)
        return result
    }
}
