import CypherProtocol
import NIO
import Foundation

struct Weak<O: AnyObject> {
    weak var object: O?
}

@available(macOS 12, iOS 15, *)
internal final class _CypherMessengerStoreCache: CypherMessengerStore {
    internal let base: CypherMessengerStore
    let eventLoop: EventLoop
    
    private var contacts: [ContactModel]? {
        willSet {
            assert(eventLoop.inEventLoop)
        }
    }
    
    private var deviceIdentities: [DeviceIdentityModel]? {
        willSet {
            assert(eventLoop.inEventLoop)
        }
    }
    
    private var messages = [UUID: ChatMessageModel]() {
        willSet {
            assert(eventLoop.inEventLoop)
        }
    }
    
    private var conversations: [ConversationModel]? {
        willSet {
            assert(eventLoop.inEventLoop)
        }
    }
    
    private var deviceConfig: Data? {
        willSet {
            assert(eventLoop.inEventLoop)
        }
    }
    
    init(base: CypherMessengerStore, eventLoop: EventLoop) {
        self.base = base
        self.eventLoop = eventLoop
    }
    
    func emptyCaches() {
        assert(eventLoop.inEventLoop)
        
        deviceConfig = nil
        contacts = nil
        conversations = nil
        deviceIdentities = nil
        messages.removeAll(keepingCapacity: true)
    }
    
    func fetchContacts() -> EventLoopFuture<[ContactModel]> {
        return eventLoop.flatSubmit {
            if let users = self.contacts {
                return self.eventLoop.makeSucceededFuture(users)
            } else {
                return self.base.fetchContacts().map { contacts in
                    self.contacts = contacts
                    return contacts
                }
            }
        }
    }
    
    func createContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            if var users = self.contacts {
                users.append(contact)
                self.contacts = users
                return self.base.createContact(contact)
            } else {
                return self.fetchContacts().map { contacts in
                    self.contacts = contacts + [contact]
                }.flatMap {
                    self.base.createContact(contact)
                }
            }
        }
    }
    
    func updateContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        assert(contacts?.contains(where: { $0 === contact }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateContact(contact)
    }
    
    func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessageModel> {
        return eventLoop.flatSubmit {
            if let message = self.messages[messageId] {
                return self.eventLoop.makeSucceededFuture(message)
            } else {
                return self.base.fetchChatMessage(byId: messageId).map { message in
                    self.messages[messageId] = message
                    return message
                }
            }
        }
    }
    
    func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessageModel> {
        return eventLoop.flatSubmit {
            return self.base.fetchChatMessage(byRemoteId: remoteId).map { message in
                if let cachedMessage = self.messages[message.id] {
                    return cachedMessage
                } else {
                    return message
                }
            }
        }
    }
    
    func fetchConversations() -> EventLoopFuture<[ConversationModel]> {
        return eventLoop.flatSubmit {
            if let conversations = self.conversations {
                return self.eventLoop.makeSucceededFuture(conversations)
            } else {
                return self.base.fetchConversations().map { conversations in
                    self.conversations = conversations
                    return conversations
                }
            }
        }
    }
    
    func createConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            if var conversations = self.conversations {
                conversations.append(conversation)
                self.conversations = conversations
                return self.base.createConversation(conversation)
            } else {
                return self.fetchConversations().map { conversations in
                    self.conversations = conversations + [conversation]
                }.flatMap {
                    self.base.createConversation(conversation)
                }
            }
        }
    }
    
    func updateConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        assert(conversations?.contains(where: { $0 === conversation }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateConversation(conversation)
    }
    
    func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentityModel]> {
        return eventLoop.flatSubmit {
            if let deviceIdentities = self.deviceIdentities {
                return self.eventLoop.makeSucceededFuture(deviceIdentities)
            } else {
                return self.base.fetchDeviceIdentities().map { deviceIdentities in
                    self.deviceIdentities = deviceIdentities
                    return deviceIdentities
                }
            }
        }
    }
    
    func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            if var deviceIdentities = self.deviceIdentities {
                deviceIdentities.append(deviceIdentity)
                self.deviceIdentities = deviceIdentities
            }
            
            return self.base.createDeviceIdentity(deviceIdentity)
        }
    }
    
    func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        assert(deviceIdentities?.contains(where: { $0 === deviceIdentity }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateDeviceIdentity(deviceIdentity)
    }
    
    func createChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            self.messages[message.id] = message
            return self.base.createChatMessage(message)
        }
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
        ).hop(to: eventLoop).map { messages in
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
        return eventLoop.flatSubmit {
            if let index = self.contacts?.firstIndex(where: { $0 === contact }) {
                self.contacts?.remove(at: index)
            }
            
            return self.base.removeContact(contact)
        }
    }
    
    func removeConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            if let index = self.conversations?.firstIndex(where: { $0 === conversation }) {
                self.conversations?.remove(at: index)
            }
            
            return self.base.removeConversation(conversation)
        }
    }
    
    func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            if let index = self.deviceIdentities?.firstIndex(where: { $0 === deviceIdentity }) {
                self.deviceIdentities?.remove(at: index)
            }
            
            return self.base.removeDeviceIdentity(deviceIdentity)
        }
    }
    
    func removeChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            self.messages[message.id] = nil
            
            return self.base.removeChatMessage(message)
        }
    }
}
