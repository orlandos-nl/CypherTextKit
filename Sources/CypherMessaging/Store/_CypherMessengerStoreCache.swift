import CypherProtocol
import NIO
import Foundation

struct Weak<O: AnyObject> {
    weak var object: O?
}

internal final class _CypherMessengerStoreCache: CypherMessengerStore {
    internal let base: CypherMessengerStore
    let eventLoop: EventLoop
    
    private var deviceIdentities: [DeviceIdentity]?
    private var messages = [UUID: ChatMessage]()
    private var conversations: [Conversation]?
    private var deviceConfig: Data?
    
    init(base: CypherMessengerStore, eventLoop: EventLoop) {
        self.base = base
        self.eventLoop = eventLoop
    }
    
    func emptyCaches() {
        deviceConfig = nil
        conversations = nil
        deviceIdentities = nil
        messages.removeAll(keepingCapacity: true)
    }
    
    func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessage> {
        if let message = messages[messageId] {
            return eventLoop.makeSucceededFuture(message)
        } else {
            return base.fetchChatMessage(byId: messageId).map { message in
                self.messages[messageId] = message
                return message
            }
        }
    }
    
    func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessage> {
        return base.fetchChatMessage(byRemoteId: remoteId).map { message in
            if let cachedMessage = self.messages[message.id] {
                return cachedMessage
            } else {
                return message
            }
        }
    }
    
    func fetchConversations() -> EventLoopFuture<[Conversation]> {
        if let conversations = conversations {
            return eventLoop.makeSucceededFuture(conversations)
        } else {
            return base.fetchConversations().map { conversations in
                self.conversations = conversations
                return conversations
            }
        }
    }
    
    func createConversation(_ conversation: Conversation) -> EventLoopFuture<Void> {
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
    
    func updateConversation(_ conversation: Conversation) -> EventLoopFuture<Void> {
        assert(conversations?.contains(where: { $0 === conversation }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateConversation(conversation)
    }
    
    func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentity]> {
        if let deviceIdentities = deviceIdentities {
            return eventLoop.makeSucceededFuture(deviceIdentities)
        } else {
            return base.fetchDeviceIdentities().map { deviceIdentities in
                self.deviceIdentities = deviceIdentities
                return deviceIdentities
            }
        }
    }
    
    func createDeviceIdentity(_ deviceIdentity: DeviceIdentity) -> EventLoopFuture<Void> {
        if var deviceIdentities = deviceIdentities {
            deviceIdentities.append(deviceIdentity)
            self.deviceIdentities = deviceIdentities
        }
        
        return base.createDeviceIdentity(deviceIdentity)
    }
    
    func updateDeviceIdentity(_ deviceIdentity: DeviceIdentity) -> EventLoopFuture<Void> {
        assert(deviceIdentities?.contains(where: { $0 === deviceIdentity }) != false)
        // Already saved in-memory, because it's a reference type
        return base.updateDeviceIdentity(deviceIdentity)
    }
    
    func createChatMessage(_ message: ChatMessage) -> EventLoopFuture<Void> {
        messages[message.id] = message
        return base.createChatMessage(message)
    }
    
    func updateChatMessage(_ message: ChatMessage) -> EventLoopFuture<Void> {
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
    ) -> EventLoopFuture<[ChatMessage]> {
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
    
    func readJobs() -> EventLoopFuture<[Job]> {
        base.readJobs()
    }
    
    func createJob(_ job: Job) -> EventLoopFuture<Void> {
        base.createJob(job)
    }
    
    func updateJob(_ job: Job) -> EventLoopFuture<Void> {
        // Forwarded to DB, caching happens inside JobQueue
        base.updateJob(job)
    }
    
    func removeJob(_ job: Job) -> EventLoopFuture<Void> {
        base.removeJob(job)
    }
}
