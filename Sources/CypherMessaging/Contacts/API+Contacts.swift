import CypherProtocol
import BSON
import Foundation
import NIO

@available(macOS 10.15, iOS 13, *)
public struct Contact: Identifiable, Hashable {
    public let messenger: CypherMessenger
    public let model: DecryptedModel<ContactModel>
    @CacheActor public let cache = Cache()
    
    @MainActor public func save() async throws {
        try await messenger.cachedStore.updateContact(model.encrypted)
        messenger.eventHandler.onUpdateContact(self)
    }
    
    @MainActor public var username: Username {
        model.username
    }
    
    public var id: UUID { model.id }
    
    public static func ==(lhs: Contact, rhs: Contact) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
    }
    
    @MainActor public func remove() async throws {
        try await messenger.cachedStore.removeContact(model.encrypted)
        messenger.eventHandler.onRemoveContact(self)
    }

    @MainActor public func refreshDevices() async throws {
        try await messenger._refreshDeviceIdentities(for: username)
    }
}

@available(macOS 10.15, iOS 13, *)
extension CypherMessenger {
    @MainActor public func listContacts() async throws -> [Contact] {
        var contacts = [Contact]()
        for contact in try await self.cachedStore.fetchContacts() {
            contacts.append(
                Contact(
                    messenger: self,
                    model: try self.decrypt(contact)
                )
            )
        }
        return contacts
    }
    
    @MainActor public func getContact(byUsername username: Username) async throws -> Contact? {
        for contact in try await listContacts() {
            if contact.model.username == username {
                return contact
            }
        }
        
        return nil
    }
    
    @MainActor public func createContact(byUsername username: Username) async throws -> Contact {
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
            self.eventHandler.onCreateContact(
                Contact(messenger: self, model: try self.decrypt(contact)),
                messenger: self
            )
            return try Contact(messenger: self, model: self.decrypt(contact))
        }
    }
}
