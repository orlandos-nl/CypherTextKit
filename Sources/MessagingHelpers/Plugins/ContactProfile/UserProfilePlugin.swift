import CypherMessaging
import NIO

public struct ContactMetadata: Codable {
    public fileprivate(set) var status: String?
    public fileprivate(set) var image: Data?
}

// TODO: Use synchronisation framework for own devices
// TODO: Select contacts to share the profile changes with
// TODO: Broadcast to a user that doesn't have a private chat
@available(macOS 12, iOS 15, *)
public struct UserProfilePlugin: Plugin {
    enum RekeyAction {
        case none, resetProfile
    }
    
    public static let pluginIdentifier = "@/contacts/profile"
    
    public init() {}
    
    public func onRekey(
        withUser username: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) async throws {
        let contact = try await messenger.createContact(byUsername: username)
        contact.metadata[self.pluginIdentifier] = Document()
        try await contact.save()
    }
    
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        guard
            message.message.messageType == .magic,
            var subType = message.message.messageSubtype,
            subType.hasPrefix("@/contacts/profile/")
        else {
            return nil
        }
        
        subType.removeFirst("@/contacts/profile/".count)
        let messenger = message.messenger
        let sender = message.sender.username
        
        switch subType {
        case "status/update":
            if sender == messenger.username {
                return try await messenger.modifyCustomConfig(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.status = message.message.text
                    return .ignore
                }
            }
            
            let contact = try await messenger.createContact(byUsername: sender)
            return try await contact.modifyMetadata(
                ofType: ContactMetadata.self,
                forPlugin: Self.self
            ) { metadata in
                metadata.status = message.message.text
                return .ignore
            }
        case "picture/update":
            guard let imageBlob = message.message.metadata["blob"] as? Binary else {
                return .ignore
            }
            
            let image = imageBlob.data
            
            if sender == messenger.username {
                return try await messenger.modifyCustomConfig(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.image = image
                    return .ignore
                }
            }
            
            let contact = try await messenger.createContact(byUsername: sender)
            return try await contact.modifyMetadata(
                ofType: ContactMetadata.self,
                forPlugin: Self.self
            ) { metadata in
                metadata.image = image
                return .ignore
            }
        default:
            return .ignore
        }
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) async throws -> SendMessageAction? {
        guard
            message.message.messageType == .magic,
            let subType = message.message.messageSubtype,
            subType.hasPrefix("@/contacts/profile/")
        else {
            return nil
        }
        
        return .send
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {}
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
}

@available(macOS 12, iOS 15, *)
extension Contact {
    public var status: String? {
        try? self.withMetadata(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { metadata in
            metadata.status
        }
    }
}

@available(macOS 12, iOS 15, *)
extension CypherMessenger {
    public func changeProfileStatus(
        to status: String
    ) async throws {
        for contact in try await listContacts() {
            let chat = try await createPrivateChat(with: contact.username)
            _ = try await chat.sendRawMessage(
                type: .magic,
                messageSubtype: "@/contacts/profile/status/update",
                text: status,
                preferredPushType: .none
            )
        }
        
        let chat = try await getInternalConversation()
        _ = try await chat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/profile/status/update",
            text: status,
            preferredPushType: .none
        )
        
        try await self.modifyCustomConfig(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { metadata in
            metadata.status = status
        }
    }
    
    public func changeProfilePicture(
        to data: Data
    ) async throws {
        for contact in try await listContacts() {
            let chat = try await createPrivateChat(with: contact.username)
            _ = try await chat.sendRawMessage(
                type: .magic,
                messageSubtype: "@/contacts/profile/picture/update",
                text: "",
                metadata: [
                    "blob": data
                ],
                preferredPushType: .none
            )
        }
        
        let chat = try await getInternalConversation()
        _ = try await chat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/contacts/profile/picture/update",
            text: "",
            metadata: [
                "blob": data
            ],
            preferredPushType: .none
        )
        
        try await self.modifyCustomConfig(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { metadata in
            metadata.image = data
        }
    }
    
    public func readProfileMetadata() async throws -> ContactMetadata {
        try await withCustomConfig(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { $0 }
    }
}
