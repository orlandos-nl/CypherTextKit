import CypherProtocol
import BSON
import Foundation
import NIO

extension CypherMessenger {
    public func listContacts() -> EventLoopFuture<[DecryptedModel<Contact>]> {
        self.cachedStore.fetchContacts().map { contacts in
            contacts.map(self.decrypt)
        }
    }
}
