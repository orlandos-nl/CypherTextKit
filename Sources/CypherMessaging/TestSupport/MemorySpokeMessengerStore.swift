import Foundation
import NIO

public enum MemoryCypherMessengerStoreError: Error {
    case notFound
}

public final class MemoryCypherMessengerStore: CypherMessengerStore {
    public let eventLoop: EventLoop
    private let salt = UUID().uuidString
    private var localConfig: Data?
    
    private var contacts = [Contact]()
    private var conversations = [Conversation]()
    private var deviceIdentities = [DeviceIdentity]()
    private var jobs = [Job]()
    private var conversationChatMessages = [UUID: [ChatMessage]]()
    private var chatMessages = [UUID: ChatMessage]()
    private var remoteMessages = [String: ChatMessage]()
    
    public init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }
    
    public func fetchContacts() -> EventLoopFuture<[Contact]> {
        return eventLoop.makeSucceededFuture(contacts)
    }
    
    public func createContact(_ contact: Contact) -> EventLoopFuture<Void> {
        contacts.append(contact)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateContact(_ contact: Contact) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func fetchConversations() -> EventLoopFuture<[Conversation]> {
        return eventLoop.makeSucceededFuture(conversations)
    }
    
    public func createConversation(_ conversation: Conversation) -> EventLoopFuture<Void> {
        conversations.append(conversation)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateConversation(_ conversation: Conversation) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentity]> {
        return eventLoop.makeSucceededFuture(deviceIdentities)
    }
    
    public func createDeviceIdentity(_ deviceIdentity: DeviceIdentity) -> EventLoopFuture<Void> {
        deviceIdentities.append(deviceIdentity)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateDeviceIdentity(_ deviceIdentity: DeviceIdentity) -> EventLoopFuture<Void> {
        // NO-OP, since Model is a reference type
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessage> {
        guard let message = chatMessages[messageId] else {
            return eventLoop.makeFailedFuture(MemoryCypherMessengerStoreError.notFound)
        }
        
        return eventLoop.makeSucceededFuture(message)
    }
    
    public func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessage> {
        guard let message = remoteMessages[remoteId] else {
            return eventLoop.makeFailedFuture(MemoryCypherMessengerStoreError.notFound)
        }
        
        return eventLoop.makeSucceededFuture(message)
    }
    
    public func createChatMessage(_ message: ChatMessage) -> EventLoopFuture<Void> {
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
    
    public func updateChatMessage(_ message: ChatMessage) -> EventLoopFuture<Void> {
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
    ) -> EventLoopFuture<[ChatMessage]> {
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
    
    public func readJobs() -> EventLoopFuture<[Job]> {
        self.eventLoop.makeSucceededFuture(jobs)
    }
    
    public func createJob(_ job: Job) -> EventLoopFuture<Void> {
        jobs.append(job)
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func updateJob(_ job: Job) -> EventLoopFuture<Void> {
        // NO-OP, since `Model` is a class
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func removeJob(_ job: Job) -> EventLoopFuture<Void> {
        jobs.removeAll { $0.id == job.id}
        return self.eventLoop.makeSucceededVoidFuture()
    }
}
