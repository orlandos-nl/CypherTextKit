import Foundation
import NIO

public enum MemoryCypherMessengerStoreError: Error {
    case notFound
}

@available(macOS 10.15, iOS 13, *)
public final actor MemoryCypherMessengerStore: CypherMessengerStore {
    private let salt = UUID().uuidString
    private var localConfig: Data?
    
    private var contacts = [ContactModel]()
    private var conversations = [ConversationModel]()
    private var deviceIdentities = [DeviceIdentityModel]()
    private var jobs = [JobModel]()
    private var conversationChatMessages = [UUID: [ChatMessageModel]]()
    private var chatMessages = [UUID: ChatMessageModel]()
    private var remoteMessages = [String: ChatMessageModel]()
    
    public init() {}
    
    public func fetchContacts() async throws -> [ContactModel] {
        return contacts
    }
    
    public func createContact(_ contact: ContactModel) async throws {
        contacts.append(contact)
    }
    
    public func updateContact(_ contact: ContactModel) async throws {
        // NO-OP, since Model is a reference type
    }
    
    public func fetchConversations() async throws -> [ConversationModel] {
        return conversations
    }
    
    public func createConversation(_ conversation: ConversationModel) async throws {
        conversations.append(conversation)
    }
    
    public func updateConversation(_ conversation: ConversationModel) async throws {
        // NO-OP, since Model is a reference type
    }
    
    public func fetchDeviceIdentities()async throws -> [DeviceIdentityModel] {
        return deviceIdentities
    }
    
    public func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws {
        deviceIdentities.append(deviceIdentity)
    }
    
    public func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws {
        // NO-OP, since Model is a reference type
    }
    
    public func fetchChatMessage(byId messageId: UUID) async throws -> ChatMessageModel {
        guard let message = chatMessages[messageId] else {
            throw MemoryCypherMessengerStoreError.notFound
        }
        
        return message
    }
    
    public func fetchChatMessage(byRemoteId remoteId: String) async throws -> ChatMessageModel {
        guard let message = remoteMessages[remoteId] else {
            throw MemoryCypherMessengerStoreError.notFound
        }
        
        return message
    }
    
    public func createChatMessage(_ message: ChatMessageModel) async throws {
        chatMessages[message.id] = message
        remoteMessages[message.remoteId] = message
        
        if var chat = conversationChatMessages[message.conversationId] {
            chat.append(message)
            conversationChatMessages[message.conversationId] = chat
        } else {
            conversationChatMessages[message.conversationId] = [message]
        }
    }
    
    public func updateChatMessage(_ message: ChatMessageModel) async throws {
        // NO-OP, since Model is a reference type
    }
    
    public func listChatMessages(
        inConversation conversationId: UUID,
        senderId: Int,
        sortedBy: SortMode,
        minimumOrder: Int?,
        maximumOrder: Int?,
        offsetBy offset: Int,
        limit: Int
    ) async throws -> [ChatMessageModel] {
        guard var messages = conversationChatMessages[conversationId] else {
            return []
        }
        
        messages = messages.filter { $0.senderId == senderId }
        messages.removeFirst(min(messages.count, offset))
        messages.removeLast(max(0, messages.count - limit))
        
        return messages
    }
    
    public func readLocalDeviceConfig() async throws -> Data {
        guard let localConfig = self.localConfig else {
            throw MemoryCypherMessengerStoreError.notFound
        }
        
        return localConfig
    }
    
    public func writeLocalDeviceConfig(_ data: Data) async throws {
        self.localConfig = data
    }
    
    public func readLocalDeviceSalt() async throws -> String {
        return salt
    }
    
    public func readJobs() async throws -> [JobModel] {
        return jobs
    }
    
    public func createJob(_ job: JobModel) async throws {
        jobs.append(job)
    }
    
    public func updateJob(_ job: JobModel) async throws {
        // NO-OP, since `Model` is a class
    }
    
    public func removeJob(_ job: JobModel) async throws {
        jobs.removeAll { $0.id == job.id}
    }
    
    public func removeContact(_ contact: ContactModel) async throws {
        contacts.removeAll { $0.id == contact.id }
    }
    
    public func removeConversation(_ conversation: ConversationModel) async throws {
        conversations.removeAll { $0.id == conversation.id }
    }
    
    public func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws {
        deviceIdentities.removeAll { $0.id == deviceIdentity.id }
    }
    
    public func removeChatMessage(_ message: ChatMessageModel) async throws {
        chatMessages[message.id] = nil
        remoteMessages[message.remoteId] = nil
    }
    
}
