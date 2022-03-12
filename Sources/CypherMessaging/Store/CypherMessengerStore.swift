import Foundation
import NIO

public enum SortMode: Sendable {
    case ascending, descending
}

@available(macOS 10.15, iOS 13, *)
public protocol CypherMessengerStore {
    func fetchContacts() async throws -> [ContactModel]
    func createContact(_ contact: ContactModel) async throws
    func updateContact(_ contact: ContactModel) async throws
    func removeContact(_ contact: ContactModel) async throws
    
    func fetchConversations() async throws -> [ConversationModel]
    func createConversation(_ conversation: ConversationModel) async throws
    func updateConversation(_ conversation: ConversationModel) async throws
    func removeConversation(_ conversation: ConversationModel) async throws
    
    func fetchDeviceIdentities() async throws -> [DeviceIdentityModel]
    func createDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws
    func updateDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws
    func removeDeviceIdentity(_ deviceIdentity: DeviceIdentityModel) async throws
    
    func fetchChatMessage(byId messageId: UUID) async throws -> ChatMessageModel
    func fetchChatMessage(byRemoteId remoteId: String) async throws -> ChatMessageModel
    func createChatMessage(_ message: ChatMessageModel) async throws
    func updateChatMessage(_ message: ChatMessageModel) async throws
    func removeChatMessage(_ message: ChatMessageModel) async throws
    func listChatMessages(
        inConversation: UUID,
        senderId: Int,
        sortedBy: SortMode,
        minimumOrder: Int?,
        maximumOrder: Int?,
        offsetBy: Int,
        limit: Int
    ) async throws -> [ChatMessageModel]
    
    func readLocalDeviceConfig() async throws -> Data
    func writeLocalDeviceConfig(_ data: Data) async throws
    func readLocalDeviceSalt() async throws -> String
    
    func readJobs() async throws -> [JobModel]
    func createJob(_ job: JobModel) async throws
    func updateJob(_ job: JobModel) async throws
    func removeJob(_ job: JobModel) async throws
}
