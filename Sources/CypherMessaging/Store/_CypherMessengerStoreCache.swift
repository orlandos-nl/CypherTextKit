import CypherProtocol
import NIO
import Foundation

struct Weak<O: AnyObject> {
    weak var object: O?
}

@globalActor final actor CypherCacheActor {
    public static let shared = CypherCacheActor()
    
    private init() {}
}

@available(macOS 10.15, iOS 13, *)
internal final class _CypherMessengerStoreCache: CypherMessengerStore {
    internal let base: CypherMessengerStore
    
    private var contacts: [ContactModel]?
    private var deviceIdentities: [DeviceIdentityModel]?
    private var messages = [UUID: ChatMessageModel]()
    private var conversations: [ConversationModel]?
    private var deviceConfig: Data?
    
    init(base: CypherMessengerStore) {
        self.base = base
    }
    
    @CypherCacheActor func emptyCaches() async {
        // TODO: Only clear entities which are knownUniquelyReferenced
        
        deviceConfig = nil
        contacts = nil
        conversations = nil
        deviceIdentities = nil
        messages.removeAll(keepingCapacity: true)
    }
    
    @CypherCacheActor func fetchContacts() async throws -> [ContactModel] {
        if let contacts = self.contacts {
            return contacts
        } else {
            let contacts = try await self.base.fetchContacts()
            self.contacts = contacts
            return contacts
        }
    }
    
    @CypherCacheActor func createContact(_ contact: ContactModel) async throws {
        if var users = self.contacts {
            users.append(contact)
            self.contacts = users
            return try await self.base.createContact(contact)
        } else {
            let contacts = try await self.fetchContacts()
            self.contacts = contacts + [contact]
            return try await self.base.createContact(contact)
        }
    }
    
    @CypherCacheActor func updateContact(_ contact: ContactModel) async throws {
        // Already saved in-memory, because it's a reference type
        return try await base.updateContact(contact)
    }
    
    @CypherCacheActor func fetchChatMessage(byId messageId: UUID) async throws -> ChatMessageModel {
        if let message = self.messages[messageId] {
            return message
        } else {
            let message = try await self.base.fetchChatMessage(byId: messageId)
            self.messages[messageId] = message
            return message
        }
    }
    
    @CypherCacheActor func fetchChatMessage(byRemoteId remoteId: String) async throws -> ChatMessageModel {
        let message = try await self.base.fetchChatMessage(byRemoteId: remoteId)
        if let cachedMessage = self.messages[message.id] {
            return cachedMessage
        } else {
            return message
        }
    }
    
    @CypherCacheActor func fetchConversations() async throws -> [ConversationModel] {
        if let conversations = self.conversations {
            return conversations
        } else {
            let conversations = try await self.base.fetchConversations()
            self.conversations = conversations
            return conversations
        }
    }
    
    @CypherCacheActor func createConversation(_ conversation: ConversationModel) async throws {
        if var conversations = self.conversations {
            conversations.append(conversation)
            self.conversations = conversations
        } else {
            let conversations = try await self.fetchConversations()
            self.conversations = conversations + [conversation]
        }
        
        return try await self.base.createConversation(conversation)
    }
    
    @CypherCacheActor func updateConversation(_ conversation: ConversationModel) async throws {
        // Already saved in-memory, because it's a reference type
        return try await base.updateConversation(conversation)
    }
    
    @CypherCacheActor func fetchDeviceIdentities() async throws -> [DeviceIdentityModel] {
        if let deviceIdentities = self.deviceIdentities {
            return deviceIdentities
        } else {
            let deviceIdentities = try await self.base.fetchDeviceIdentities()
            self.deviceIdentities = deviceIdentities
            return deviceIdentities
        }
    }
    
    @CypherCacheActor func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws {
        if var deviceIdentities = self.deviceIdentities {
            deviceIdentities.append(deviceIdentity)
            self.deviceIdentities = deviceIdentities
        }
        
        return try await self.base.createDeviceIdentity(deviceIdentity)
    }
    
    @CypherCacheActor func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws {
        assert(deviceIdentities?.contains(where: { $0 === deviceIdentity }) != false)
        // Already saved in-memory, because it's a reference type
        return try await base.updateDeviceIdentity(deviceIdentity)
    }
    
    @CypherCacheActor func createChatMessage(_ message: ChatMessageModel) async throws {
        self.messages[message.id] = message
        return try await self.base.createChatMessage(message)
    }
    
    @CypherCacheActor func updateChatMessage(_ message: ChatMessageModel) async throws {
        // Already saved in-memory, because it's a reference type
        try await base.updateChatMessage(message)
    }
    
    @CypherCacheActor func listChatMessages(
        inConversation conversation: UUID,
        senderId: Int,
        sortedBy sortMode: SortMode,
        minimumOrder: Int?,
        maximumOrder: Int?,
        offsetBy offset: Int,
        limit: Int
    ) async throws -> [ChatMessageModel] {
        try await base.listChatMessages(
            inConversation: conversation,
            senderId: senderId,
            sortedBy: sortMode,
            minimumOrder: minimumOrder,
            maximumOrder: maximumOrder,
            offsetBy: offset,
            limit: limit
        ).map { message in
            if let cachedMessage = self.messages[message.id] {
                return cachedMessage
            } else {
                self.messages[message.id] = message
                return message
            }
        }
    }
    
    @CypherCacheActor func readLocalDeviceConfig() async throws -> Data {
        try await base.readLocalDeviceConfig()
    }
    
    @CypherCacheActor func writeLocalDeviceConfig(_ data: Data) async throws {
        try await base.writeLocalDeviceConfig(data)
    }
    
    @CypherCacheActor func readLocalDeviceSalt() async throws -> String {
        try await base.readLocalDeviceSalt()
    }
    
    @CypherCacheActor func readJobs() async throws -> [JobModel] {
        try await base.readJobs()
    }
    
    @CypherCacheActor func createJob(_ job: JobModel) async throws {
        try await base.createJob(job)
    }
    
    @CypherCacheActor func updateJob(_ job: JobModel) async throws {
        // Forwarded to DB, caching happens inside JobQueue
        try await base.updateJob(job)
    }
    
    @CypherCacheActor func removeJob(_ job: JobModel) async throws {
        try await base.removeJob(job)
    }
    
    @CypherCacheActor func removeContact(_ contact: ContactModel) async throws {
        if let index = self.contacts?.firstIndex(where: { $0 === contact }) {
            self.contacts?.remove(at: index)
        }
        
        return try await self.base.removeContact(contact)
    }
    
    @CypherCacheActor func removeConversation(_ conversation: ConversationModel) async throws {
        if let index = self.conversations?.firstIndex(where: { $0 === conversation }) {
            self.conversations?.remove(at: index)
        }
        
        return try await self.base.removeConversation(conversation)
    }
    
    @CypherCacheActor func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws {
        if let index = self.deviceIdentities?.firstIndex(where: { $0 === deviceIdentity }) {
            self.deviceIdentities?.remove(at: index)
        }
        
        return try await self.base.removeDeviceIdentity(deviceIdentity)
    }
    
    @CypherCacheActor func removeChatMessage(_ message: ChatMessageModel) async throws {
        self.messages[message.id] = nil
        
        return try await self.base.removeChatMessage(message)
    }
}
