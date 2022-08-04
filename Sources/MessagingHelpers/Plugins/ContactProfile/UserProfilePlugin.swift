import CypherMessaging
import NIO

public struct ContactMetadata: Codable {
    public var status: String?
    public var nickname: String?
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var phone: String?
    public var image: Data?
}

// TODO: Select contacts to share the profile changes with
// TODO: Broadcast to a user that doesn't have a private chat
@available(macOS 10.15, iOS 13, *)
public struct UserProfilePlugin: Plugin {
    enum RekeyAction {
        case none, resetProfile
    }
    
    public static let pluginIdentifier = "@/contacts/profile"
    
    public init() {}
    
    public func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) {
        Task {
            let internalChat = try await messenger.getInternalConversation()
            
            try await messenger.withCustomConfig(
                ofType: ContactMetadata.self,
                forPlugin: Self.self
            ) { metadata in
                if let status = metadata.status {
                    try await internalChat.sendMagicPacket(
                        messageSubtype: "@/contacts/profile/status/update",
                        text: status,
                        toDeviceId: deviceId
                    )
                }
                
                if let firstName = metadata.firstName, let lastName = metadata.lastName {
                    try await internalChat.sendMagicPacket(
                        messageSubtype: "@/contacts/profile/name/update",
                        text: "",
                        metadata: [
                            "firstName": firstName,
                            "lastName": lastName,
                        ],
                        toDeviceId: deviceId
                    )
                }
                
                if let image = metadata.image {
                    try await internalChat.sendMagicPacket(
                        messageSubtype: "@/contacts/profile/picture/update",
                        text: "",
                        metadata: [
                            "blob": Binary(buffer: ByteBuffer(data: image))
                        ],
                        toDeviceId: deviceId
                    )
                }
            }
        }
    }
    
    public func onOtherUserDeviceRegistery(username: Username, deviceId: DeviceId, messenger: CypherMessenger) {
        Task {
            // TODO: Select contacts to share the profile changes with
            // TODO: Broadcast to a user that doesn't have a private chat
            let chat = try await messenger.createPrivateChat(with: username)
            
            try await messenger.withCustomConfig(
                ofType: ContactMetadata.self,
                forPlugin: Self.self
            ) { metadata in
                if let status = metadata.status {
                    try await chat.sendMagicPacket(
                        messageSubtype: "@/contacts/profile/status/update",
                        text: status,
                        toDeviceId: deviceId
                    )
                }
                
                if let firstName = metadata.firstName, let lastName = metadata.lastName {
                    try await chat.sendMagicPacket(
                        messageSubtype: "@/contacts/profile/name/update",
                        text: "",
                        metadata: [
                            "firstName": firstName,
                            "lastName": lastName,
                        ],
                        toDeviceId: deviceId
                    )
                }
                
                if let image = metadata.image {
                    try await chat.sendMagicPacket(
                        messageSubtype: "@/contacts/profile/picture/update",
                        text: "",
                        metadata: [
                            "blob": Binary(buffer: ByteBuffer(data: image))
                        ],
                        toDeviceId: deviceId
                    )
                }
            }
        }
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
        let username = messenger.username
        
        func withMetadata(perform: @escaping (inout ContactMetadata) -> ()) async throws -> ProcessMessageAction {
            if sender == username {
                return try await messenger.modifyCustomConfig(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    perform(&metadata)
                    return .ignore
                }
            } else {
                let contact = try await messenger.createContact(byUsername: sender)
                return try await contact.modifyMetadata(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    perform(&metadata)
                    return .ignore
                }
            }
        }
        
        switch subType {
        case "status/update":
            return try await withMetadata { $0.status = message.message.text }
        case "name/update":
            guard
                let firstName = message.message.metadata["firstName"] as? String,
                let lastName = message.message.metadata["lastName"] as? String
            else {
                return .ignore
            }
            
            return try await withMetadata { metadata in
                metadata.firstName = firstName
                metadata.lastName = lastName
            }
        case "picture/update":
            guard let imageBlob = message.message.metadata["blob"] as? Binary else {
                return .ignore
            }
            
            return try await withMetadata { metadata in
                metadata.image = imageBlob.data
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
}

@available(macOS 10.15, iOS 13, *)
extension Contact {
    @MainActor public var status: String? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.status
        )
    }
    
    @MainActor public var image: Data? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.image
        )
    }
    
    @MainActor public var firstName: String? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.firstName
        )
    }
    
    @MainActor public var lastName: String? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.lastName
        )
    }
    
    @MainActor public var email: String? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.email
        )
    }
    
    @MainActor public var phone: String? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.phone
        )
    }
    
    @MainActor public var nickname: String? {
        (try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: \.nickname
        ))
    }
    
    @MainActor public var contactMetadata: ContactMetadata? {
        try? self.model.getProp(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self,
            run: { $0 }
        )
    }
    
    @CryptoActor public func setNickname(to nickname: String) async throws {
        try await self.model.withMetadata(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { metadata in
            metadata.nickname = nickname
        }
    }
}

@available(macOS 10.15, iOS 13, *)
extension CypherMessenger {
    public func changeProfileStatus(
        to status: String
    ) async throws {
        for contact in try await listContacts() {
            let chat = try await createPrivateChat(with: contact.model.username)
            try await chat.sendRawMessage(
                type: .magic,
                messageSubtype: "@/contacts/profile/status/update",
                text: status,
                preferredPushType: .none
            )
        }
        
        let chat = try await getInternalConversation()
        try await chat.sendRawMessage(
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
    
    // TODO: Update firstName, lastName, phone, email
    // TODO: Allow app to control which contacts get this info
    
    private func sendProfileUpdate(subtype: String, text: String, metadata: Document = [:]) async throws {
        // TODO: limit who can see your changes?
        for contact in try await listContacts() {
            let chat = try await createPrivateChat(with: contact.model.username)
            try await chat.sendMagicPacketMessage(
                messageSubtype: "@/contacts/profile/\(subtype)",
                text: text,
                metadata: metadata,
                preferredPushType: .none
            )
        }
        
        let chat = try await getInternalConversation()
        try await chat.sendMagicPacket(
            messageSubtype: "@/contacts/profile/\(subtype)",
            text: text,
            metadata: metadata
        )
    }
    
    public func changeName(
        firstName: String,
        lastName: String
    ) async throws {
        try await sendProfileUpdate(subtype: "name/update", text: "", metadata: [
            "firstName": firstName,
            "lastName": lastName
        ])
        
        try await self.modifyCustomConfig(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { metadata in
            metadata.firstName = firstName
            metadata.lastName = lastName
        }
    }
    
    public func changeProfilePicture(
        to data: Data
    ) async throws {
        try await sendProfileUpdate(subtype: "picture/update", text: "", metadata: [
            "blob": data
        ])
        
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
