import Foundation
import NIO

public enum SortMode {
    case ascending, descending
}

public protocol CypherMessengerStore {
    func fetchContacts() -> EventLoopFuture<[ContactModel]>
    func createContact(_ contact: ContactModel) -> EventLoopFuture<Void>
    func updateContact(_ contact: ContactModel) -> EventLoopFuture<Void>
    func removeContact(_ contact: ContactModel) -> EventLoopFuture<Void>
    
    func fetchConversations() -> EventLoopFuture<[ConversationModel]>
    func createConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void>
    func updateConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void>
    func removeConversation(_ conversation: ConversationModel) -> EventLoopFuture<Void>
    
    func fetchDeviceIdentities() -> EventLoopFuture<[DeviceIdentityModel]>
    func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void>
    func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void>
    func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) -> EventLoopFuture<Void>
    
    func fetchChatMessage(byId messageId: UUID) -> EventLoopFuture<ChatMessageModel>
    func fetchChatMessage(byRemoteId remoteId: String) -> EventLoopFuture<ChatMessageModel>
    func createChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void>
    func updateChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void>
    func removeChatMessage(_ message: ChatMessageModel) -> EventLoopFuture<Void>
    func listChatMessages(
        inConversation: UUID,
        senderId: Int,
        sortedBy: SortMode,
        minimumOrder: Int?,
        maximumOrder: Int?,
        offsetBy: Int,
        limit: Int
    ) -> EventLoopFuture<[ChatMessageModel]>
    
    func readLocalDeviceConfig() -> EventLoopFuture<Data>
    func writeLocalDeviceConfig(_ data: Data) -> EventLoopFuture<Void>
    func readLocalDeviceSalt() -> EventLoopFuture<String>
    
    func readJobs() -> EventLoopFuture<[JobModel]>
    func createJob(_ job: JobModel) -> EventLoopFuture<Void>
    func updateJob(_ job: JobModel) -> EventLoopFuture<Void>
    func removeJob(_ job: JobModel) -> EventLoopFuture<Void>
}
