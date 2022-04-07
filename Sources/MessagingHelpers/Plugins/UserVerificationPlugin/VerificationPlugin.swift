import CypherMessaging
import NIO

fileprivate struct UserVerificationMetadata: Codable {
    var isVerified: Bool
}

@available(macOS 10.15, iOS 13, *)
public struct UserVerificationPlugin: Plugin {
    public static let pluginIdentifier = "@/user-verification"
    
    public init() {}
    
    public func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) {
        Task {
            var verifiedFlags = Document()
            let internalChat = try await messenger.getInternalConversation()
            
            for contact in try await messenger.listContacts() {
                await verifiedFlags[contact.username.raw] = contact.isVerified
            }
            
            try await internalChat.sendMagicPacket(
                messageSubtype: Self.pluginIdentifier,
                text: "",
                metadata: verifiedFlags,
                toDeviceId: deviceId
            )
        }
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        guard message.message.messageType == .magic, message.message.messageSubtype == Self.pluginIdentifier else {
            return nil
        }
        
        for (username, value) in message.message.metadata {
            let username = Username(username)
            guard let isVerified = value as? Bool else {
                // Unknown operation
                debugLog("Unknown verification change")
                continue
            }
            
            let contact = try await message.messenger.createContact(byUsername: username)
            try await contact.modifyMetadata(
                ofType: UserVerificationMetadata.self,
                forPlugin: UserVerificationPlugin.self
            ) { metadata in
                metadata.isVerified = isVerified
            }
        }
        
        return .ignore
    }
}

@available(macOS 10.15, iOS 13, *)
extension Contact {
    @MainActor public var isVerified: Bool {
        (try? self.model.getProp(
            ofType: UserVerificationMetadata.self,
            forPlugin: UserVerificationPlugin.self,
            run: \.isVerified
        )) ?? false
    }
    
    @MainActor func setVerification(to isVerified: Bool) async throws {
        try await modifyMetadata(
            ofType: UserVerificationMetadata.self,
            forPlugin: UserVerificationPlugin.self
        ) { metadata in
            metadata.isVerified = isVerified
        }
        
        let internalChat = try await messenger.getInternalConversation()
        try await internalChat.sendMagicPacket(
            messageSubtype: UserVerificationPlugin.pluginIdentifier,
            text: "",
            metadata: [
                self.username.raw: isVerified
            ]
        )
    }
}
