import CypherProtocol
import BSON
import Foundation
import NIO

public struct Contact {
    public let messenger: CypherMessenger
    let model: DecryptedModel<ContactModel>
    public var eventLoop: EventLoop { messenger.eventLoop }
    public var username: Username { model.username }
    public var metadata: Document {
        get { model.metadata }
        nonmutating set { model.metadata = newValue }
    }
    
    public func save() -> EventLoopFuture<Void> {
        messenger.cachedStore.updateContact(model.encrypted)
    }
}

extension CypherMessenger {
    public func listContacts() -> EventLoopFuture<[Contact]> {
        self.cachedStore.fetchContacts().map { contacts in
            contacts.map { contact in
                return Contact(
                    messenger: self,
                    model: self.decrypt(contact)
                )
            }
        }
    }
    
    public func getContact(byUsername username: Username) -> EventLoopFuture<Contact?> {
        listContacts().map { contacts in
            contacts.first { $0.username == username }
        }
    }
    
    public func createContact(byUsername username: Username) -> EventLoopFuture<Contact> {
        if username == self.username {
            return self.eventLoop.makeFailedFuture(CypherSDKError.badInput)
        }
        
        return self.getContact(byUsername: username).flatMap { contact in
            if let contact = contact {
                return self.eventLoop.makeSucceededFuture(contact)
            } else {
                return self.eventHandler.createContactMetadata(
                    for: username,
                    messenger: self
                ).flatMap { metadata -> EventLoopFuture<ContactModel> in
                    return self.transport.readKeyBundle(
                        forUsername: username
                    ).flatMapThrowing { userConfig in
                        try ContactModel(
                            props: ContactModel.SecureProps(
                                username: username,
                                config: userConfig,
                                metadata: metadata
                            ),
                            encryptionKey: self.databaseEncryptionKey
                        )
                    }
                }.flatMap { contact in
                    self.cachedStore.createContact(contact).map {
                        Contact(messenger: self, model: self.decrypt(contact))
                    }
                }
            }
        }
    }
}
