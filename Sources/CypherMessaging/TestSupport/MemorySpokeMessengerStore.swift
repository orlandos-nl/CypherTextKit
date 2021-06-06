import Foundation
import NIO

public enum MemoryCypherMessengerStoreError: Error {
    case notFound
}

public final class MemoryCypherMessengerStore: CypherMessengerStore {
    public let eventLoop: EventLoop
    private let salt = UUID().uuidString
    private var localConfig: Data?
    
    private var contacts = [ContactModel]()
    private var conversations = [ConversationModel]()
    private var deviceIdentities = [DeviceIdentityModel]()
    private var jobs = [JobModel]()
    private var conversationChatMessages = [UUID: [ChatMessageModel]]()
    private var chatMessages = [UUID: ChatMessageModel]()
    private var remoteMessages = [String: ChatMessageModel]()
    
    public init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }
    
    public func fetchContacts() -> EventLoopFuture<[ContactModel]> {
        return eventLoop.makeSucceededFuture(contacts)
    }
    
    public func createContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        contacts.append(contact)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func fetchConversations() -> EventLoopFuture<[ConversationModel]> {
        return eventLoop.makeSucceededFuture(conversations)
    }
    
    public func createConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        conversations.append(conversation)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentityModel]> {
        return eventLoop.makeSucceededFuture(deviceIdentities)
    }
    
    public func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        deviceIdentities.append(deviceIdentity)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessageModel> {
        guard let message = chatMessages[messageId] else {
            return eventLoop.makeFailedFuture(MemoryCypherMessengerStoreError.notFound)
        }
        
        return eventLoop.makeSucceededFuture(message)
    }
    
    public func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessageModel> {
        guard let message = remoteMessages[remoteId] else {
            return eventLoop.makeFailedFuture(MemoryCypherMessengerStoreError.notFound)
        }
        
        return eventLoop.makeSucceededFuture(message)
    }
    
    public func createChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        chatMessages[message.id] = message
        remoteMessages[message.remoteId] = message
        
        if var chat = conversationChatMessages[message.conversationId] {
            chat.append(message)
            conversationChatMessages[message.conversationId] = chat
        } else {
            conversationChatMessages[message.conversationId] = [message]
        }
        
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func listChatMessages(
        inConversation conversationId: UUID,
        senderId: Int,
        sortedBy: SortMode,
        minimumOrder: Int?,
        maximumOrder: Int?,
        offsetBy offset: Int,
        limit: Int
    ) -> EventLoopFuture<[ChatMessageModel]> {
        guard var messages = conversationChatMessages[conversationId] else {
            return eventLoop.makeSucceededFuture([])
        }
        
        messages = messages.filter { $0.senderId == senderId }
        messages.removeFirst(min(messages.count, offset))
        messages.removeLast(max(0, messages.count - limit))
        
        return eventLoop.makeSucceededFuture(messages)
    }
    
    public func readLocalDeviceConfig() -> EventLoopFuture<Data> {
        guard let localConfig = self.localConfig else {
            return eventLoop.makeFailedFuture(MemoryCypherMessengerStoreError.notFound)
        }
        
        return eventLoop.makeSucceededFuture(localConfig)
    }
    
    public func writeLocalDeviceConfig(_ data: Data) -> EventLoopFuture<Void> {
        self.localConfig = data
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func readLocalDeviceSalt() -> EventLoopFuture<String> {
        return eventLoop.makeSucceededFuture(salt)
    }
    
    public func readJobs() -> EventLoopFuture<[JobModel]> {
        self.eventLoop.makeSucceededFuture(jobs)
    }
    
    public func createJob(_ job: JobModel) -> EventLoopFuture<Void> {
        jobs.append(job)
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateJob(_ job: JobModel) -> EventLoopFuture<Void> {
        // NO-OP, since `Model` is a class
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func removeJob(_ job: JobModel) -> EventLoopFuture<Void> {
        jobs.removeAll { $0.id == job.id}
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func removeContact(_ contact: ContactModel) -> EventLoopFuture<Void> {
        contacts.removeAll { $0.id == contact.id }
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func removeConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void> {
        conversations.removeAll { $0.id == conversation.id }
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void> {
        deviceIdentities.removeAll { $0.id == deviceIdentity.id }
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func removeChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void> {
        chatMessages[message.id] = nil
        remoteMessages[message.remoteId] = nil
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
}
