import Foundation
import NIO

public enum SortMode {
    case ascending, descending
}

public protocol CypherMessengerStore {
    func fetchConversations() -> EventLoopFuture<[Conversation]>
    func createConversation(_ conversation: Conversation) -> EventLoopFuture<Void>
    func updateConversation(_ conversation: Conversation) -> EventLoopFuture<Void>
    
    func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentity]>
    func createDeviceIdentity(_ deviceIdentity: DeviceIdentity) -> EventLoopFuture<Void>
    func updateDeviceIdentity(_ deviceIdentity: DeviceIdentity) -> EventLoopFuture<Void>
    
    func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessage>
    func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessage>
    func createChatMessage(_ message: ChatMessage) -> EventLoopFuture<Void>
    func updateChatMessage(_ message: ChatMessage) -> EventLoopFuture<Void>
    func listChatMessages(
        inConversation: UUID,
        senderId: Int,
        sortedBy: SortMode,
        offsetBy: Int,
        limit: Int
    ) -> EventLoopFuture<[ChatMessage]>
    
    func readLocalDeviceConfig() -> EventLoopFuture<Data>
    func writeLocalDeviceConfig(_ data: Data) -> EventLoopFuture<Void>
    func readLocalDeviceSalt() -> EventLoopFuture<String>
    
    func readJobs() -> EventLoopFuture<[Job]>
    func createJob(_ job: Job) -> EventLoopFuture<Void>
    func updateJob(_ job: Job) -> EventLoopFuture<Void>
    func removeJob(_ job: Job) -> EventLoopFuture<Void>
}
