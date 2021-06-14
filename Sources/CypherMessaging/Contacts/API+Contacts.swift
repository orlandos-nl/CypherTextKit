import CypherProtocol
import BSON
import Foundation
import NIO

@available(macOS 12, iOS 15, *)
public struct Contact: Identifiable {
    public let messenger: CypherMessenger
    public let model: DecryptedModel<ContactModel>
    public var eventLoop: EventLoop { messenger.eventLoop }
    
    public func save() async throws {
        try await messenger.cachedStore.updateContact(model.encrypted)
    }
    
    public var username: Username {
        model.username
    }
    
    public var id: UUID { model.id }
}

@available(macOS 12, iOS 15, *)
extension CypherMessenger {
    public func listContacts() async throws -> [Contact] {
        try await self.cachedStore.fetchContacts().asyncMap { contact in
            Contact(
                messenger: self,
                model: try await self.decrypt(contact)
            )
        }
    }
    
    public func getContact(byUsername username: Username) async throws -> Contact? {
        for contact in try await listContacts() {
            if contact.model.username == username {
                return contact
            }
        }
        
        return nil
    }
    
    public func createContact(byUsername username: Username)  async throws -> Contact {
        if username == self.username {
            throw CypherSDKError.badInput
        }
        
        if let contact = try await self.getContact(byUsername: username) {
            return contact
        } else {
            let metadata = try await self.eventHandler.createContactMetadata(
                for: username,
                messenger: self
            )
            
            let userConfig = try await self.transport.readKeyBundle(
                forUsername: username
            )
            
            let contact = try ContactModel(
                props: ContactModel.SecureProps(
                    username: username,
                    config: userConfig,
                    metadata: metadata
                ),
                encryptionKey: self.databaseEncryptionKey
            )
                
            try await self.cachedStore.createContact(contact)
            return try await Contact(messenger: self, model: self.decrypt(contact))
        }
    }
}
