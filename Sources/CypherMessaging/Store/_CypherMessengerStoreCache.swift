import CypherProtocol
import NIO
import Foundation

struct Weak<O: AnyObject> {
    weak var object: O?
}

internal final class _CypherMessengerStoreCache: CypherMessengerStore {
    internal let base: CypherMessengerStore
    let eventLoop: EventLoop
    
    private var contacts: [ContactModel]?
    private var deviceIdentities: [DeviceIdentityModel]?
    private var messages = [UUID: ChatMessageModel]()
    private var conversations: [ConversationModel]?
    private var deviceConfig: Data?
    
    init(base: CypherMessengerStore, eventLoop: EventLoop) {
        self.base = base
        self.eventLoop = eventLoop
    }
    
    func emptyCaches() {
        deviceConfig = nil
        contacts = nil
        conversations = nil
        deviceIdentities = nil
        messages.removeAll(keepingCapacity: true)
    }
    
    func fetchContacts() -> EventLoopFuture<[ContactModel]> {
        if let users = contacts {
            return eventLoop.makeSucceededFuture(users)
        } else {
            return base.fetchContacts().map { contacts in
                self.contacts = contacts
                return contacts
            }
        }
    }
    
    func createContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        if var users = contacts {
            users.append(contact)
            self.contacts = users
            return base.createContact(contact)
        } else {
            return fetchContacts().map { contacts in
                self.contacts = contacts + [contact]
            }.flatMap {
                self.base.createContact(contact)
            }
        }
    }
    
    func updateContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        assert(contacts?.contains(where: { $0 === contact }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateContact(contact)
    }
    
    func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessageModel> {
        if let message = messages[messageId] {
            return eventLoop.makeSucceededFuture(message)
        } else {
            return base.fetchChatMessage(byId: messageId).map { message in
                self.messages[messageId] = message
                return message
            }
        }
    }
    
    func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessageModel> {
        return base.fetchChatMessage(byRemoteId: remoteId).map { message in
            if let cachedMessage = self.messages[message.id] {
                return cachedMessage
            } else {
                return message
            }
        }
    }
    
    func fetchConversations() -> EventLoopFuture<[ConversationModel]> {
        if let conversations = conversations {
            return eventLoop.makeSucceededFuture(conversations)
        } else {
            return base.fetchConversations().map { conversations in
                self.conversations = conversations
                return conversations
            }
        }
    }
    
    func createConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        if var conversations = conversations {
            conversations.append(conversation)
            self.conversations = conversations
            return base.createConversation(conversation)
        } else {
            return fetchConversations().map { conversations in
                self.conversations = conversations + [conversation]
            }.flatMap {
                self.base.createConversation(conversation)
            }
        }
    }
    
    func updateConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        assert(conversations?.contains(where: { $0 === conversation }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateConversation(conversation)
    }
    
    func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentityModel]> {
        if let deviceIdentities = deviceIdentities {
            return eventLoop.makeSucceededFuture(deviceIdentities)
        } else {
            return base.fetchDeviceIdentities().map { deviceIdentities in
                self.deviceIdentities = deviceIdentities
                return deviceIdentities
            }
        }
    }
    
    func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        if var deviceIdentities = deviceIdentities {
            deviceIdentities.append(deviceIdentity)
            self.deviceIdentities = deviceIdentities
        }
        
        return base.createDeviceIdentity(deviceIdentity)
    }
    
    func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        assert(deviceIdentities?.contains(where: { $0 === deviceIdentity }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateDeviceIdentity(deviceIdentity)
    }
    
    func createChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        messages[message.id] = message
        return base.createChatMessage(message)
    }
    
    func updateChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        // Already saved in-memory, because it's a reference type
        base.updateChatMessage(message)
    }
    
    func listChatMessages(
        inConversation conversation: UUID,
        senderId: Int,
        sortedBy sortMode: SortMode,
        minimumOrder: Int?,
        maximumOrder: Int?,
        offsetBy offset: Int,
        limit: Int
    ) -> EventLoopFuture<[ChatMessageModel]> {
        base.listChatMessages(
            inConversation: conversation,
            senderId: senderId,
            sortedBy: sortMode,
            minimumOrder: minimumOrder,
            maximumOrder: maximumOrder,
            offsetBy: offset,
            limit: limit
        ).map { messages in
            messages.map { message in
                if let cachedMessage = self.messages[message.id] {
                    return cachedMessage
                } else {
                    self.messages[message.id] = message
                    return message
                }
            }
        }
    }
    
    func readLocalDeviceConfig() -> EventLoopFuture<Data> {
        base.readLocalDeviceConfig()
    }
    
    func writeLocalDeviceConfig(_ data: Data) -> EventLoopFuture<Void> {
        base.writeLocalDeviceConfig(data)
    }
    
    func readLocalDeviceSalt() -> EventLoopFuture<String> {
        base.readLocalDeviceSalt()
    }
    
    func readJobs() -> EventLoopFuture<[JobModel]> {
        base.readJobs()
    }
    
    func createJob(_ job: JobModel) -> EventLoopFuture<Void> {
        base.createJob(job)
    }
    
    func updateJob(_ job: JobModel) -> EventLoopFuture<Void> {
        // Forwarded to DB, caching happens inside JobQueue
        base.updateJob(job)
    }
    
    func removeJob(_ job: JobModel) -> EventLoopFuture<Void> {
        base.removeJob(job)
    }
    
    func removeContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        if let index = contacts?.firstIndex(where: { $0 === contact }) {
            contacts?.remove(at: index)
        }
        
        return base.removeContact(contact)
    }
    
    func removeConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        if let index = conversations?.firstIndex(where: { $0 === conversation }) {
            conversations?.remove(at: index)
        }
        
        return base.removeConversation(conversation)
    }
    
    func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        if let index = deviceIdentities?.firstIndex(where: { $0 === deviceIdentity }) {
            deviceIdentities?.remove(at: index)
        }
        
        return base.removeDeviceIdentity(deviceIdentity)
    }
    
    func removeChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        messages[message.id] = nil
        
        return base.removeChatMessage(message)
    }
}
