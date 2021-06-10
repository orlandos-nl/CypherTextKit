import Crypto
import BSON
import Foundation
import CypherProtocol

public final class ConversationModel: Model {
    public struct SecureProps: Codable {
        public var members: Set<Username>
        public var metadata: Document
        public var localOrder: Int
    }
    
    public let id: UUID
    
    public var props: Encrypted<SecureProps>
    
    public init(id: UUID, props: Encrypted<SecureProps>) {
        self.id = id
        self.props = props
    }
    
    internal init(
        props: SecureProps,
        encryptionKey: SymmetricKey
    ) throws {
        self.id = UUID()
        self.props = try .init(props, encryptionKey: encryptionKey)
    }
}

extension DecryptedModel where M == ConversationModel {
    public var members: Set<Username> {
        get { props.members }
    }
    public var metadata: Document {
        get { props.metadata }
    }
    public var localOrder: Int {
        get { props.localOrder }
    }
    
    func getNextLocalOrder() async throws -> Int {
        let order = localOrder
        try await setProp(at: \.localOrder, to: order &+ 1)
        return order
   }
}

public final class DeviceIdentityModel: Model {
    public struct SecureProps: Codable {
        let username: Username
        let deviceId: DeviceId
        let senderId: Int
        let publicKey: PublicKey
        let identity: PublicSigningKey
        var doubleRatchet: DoubleRatchetHKDF<SHA512>.State?
    }
    
    public let id: UUID

    public var props: Encrypted<SecureProps>
    
    public init(id: UUID, props: Encrypted<SecureProps>) {
        self.id = id
        self.props = props
    }
    
    internal init(
        props: SecureProps,
        encryptionKey: SymmetricKey
    ) throws {
        self.id = UUID()
        self.props = try .init(props, encryptionKey: encryptionKey)
    }
}

extension DecryptedModel where M == DeviceIdentityModel {
    public var username: Username {
        get { props.username }
    }
    public var deviceId: DeviceId {
        get { props.deviceId }
    }
    public var senderId: Int {
        get { props.senderId }
    }
    public var publicKey: PublicKey {
        get { props.publicKey }
    }
    public var identity: PublicSigningKey {
        get { props.identity }
    }
    public var doubleRatchet: DoubleRatchetHKDF<SHA512>.State? {
        get { props.doubleRatchet }
    }
    func updateDoubleRatchetState(to newValue: DoubleRatchetHKDF<SHA512>.State?) async throws {
        try await setProp(at: \.doubleRatchet, to: newValue)
    }
}

public final class ContactModel: Model {
    public struct SecureProps: Codable {
        public let username: Username
        public internal(set) var config: UserConfig
        public var metadata: Document
    }
    
    public let id: UUID

    public var props: Encrypted<SecureProps>
    
    public init(id: UUID, props: Encrypted<SecureProps>) {
        self.id = id
        self.props = props
    }
    
    internal init(
        props: SecureProps,
        encryptionKey: SymmetricKey
    ) throws {
        self.id = UUID()
        self.props = try .init(props, encryptionKey: encryptionKey)
    }
}

extension DecryptedModel where M == ContactModel {
    public var username: Username {
        get { props.username }
    }
    public var config: UserConfig {
        get { props.config }
    }
    public var metadata: Document {
        get { props.metadata }
    }
    func updateConfig(to newValue: UserConfig) async throws {
        try await self.setProp(at: \.config, to: newValue)
    }
}

public enum MarkMessageResult {
    case success, error, notModified
}

@available(macOS 12, iOS 15, *)
public final class ChatMessageModel: Model {
    public enum DeliveryState: Int, Codable {
        case none = 0
        case undelivered = 1
        case received = 2
        case read = 3
        case revoked = 4
        
        @discardableResult
        public mutating func transition(to newState: DeliveryState) -> MarkMessageResult {
            switch (self, newState) {
            case (.none, _), (.undelivered, _), (.received, .read), (.received, .revoked):
                self = newState
                return .success
            case (_, .undelivered), (_, .none), (.read, .revoked), (.read, .received), (.revoked, .read), (.revoked, .received):
                return .error
            case (.revoked, .revoked), (.read, .read), (.received, .received):
                return .notModified
            }
        }
    }
    
    public struct SecureProps: Codable {
        private enum CodingKeys: String, CodingKey {
            case sendDate = "a"
            case receiveDate = "b"
            case deliveryState = "c"
            case message = "d"
            case senderUser = "e"
            case senderDeviceId = "f"
        }
        
        public let sendDate: Date
        public let receiveDate: Date
        public internal(set) var deliveryState: DeliveryState
        public var message: SingleCypherMessage
        public let senderUser: Username
        public let senderDeviceId: DeviceId
        
        init(
            sending message: SingleCypherMessage,
            senderUser: Username,
            senderDeviceId: DeviceId
        ) {
            self.sendDate = Date()
            self.receiveDate = Date()
            self.deliveryState = .none
            self.message = message
            self.senderUser = senderUser
            self.senderDeviceId = senderDeviceId
        }
        
        init(
            receiving message: SingleCypherMessage,
            sentAt: Date,
            senderUser: Username,
            senderDeviceId: DeviceId
        ) {
            self.sendDate = sentAt
            self.receiveDate = Date()
            self.deliveryState = .received
            self.message = message
            self.senderUser = senderUser
            self.senderDeviceId = senderDeviceId
        }
    }
    
    // `id` must be unique, or rejected when saving
    public let id: UUID
    
    public let conversationId: UUID
    public let senderId: Int
    public let order: Int
    
    // `remoteId` must be unique, or rejected when saving
    public let remoteId: String
    
    public var props: Encrypted<SecureProps>
    
    public init(
        id: UUID,
        conversationId: UUID,
        senderId: Int,
        order: Int,
        remoteId: String = UUID().uuidString,
        props: Encrypted<SecureProps>
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.order = order
        self.remoteId = remoteId
        self.props = props
    }
    
    internal init(
        conversationId: UUID,
        senderId: Int,
        order: Int,
        remoteId: String = UUID().uuidString,
        props: SecureProps,
        encryptionKey: SymmetricKey
    ) throws {
        self.id = UUID()
        self.conversationId = conversationId
        self.senderId = senderId
        self.order = order
        self.remoteId = remoteId
        self.props = try .init(props, encryptionKey: encryptionKey)
    }
}

extension DecryptedModel where M == ChatMessageModel {
    public var sendDate: Date {
        get { props.sendDate }
    }
    public var receiveDate: Date {
        get { props.receiveDate }
    }
    public var deliveryState: ChatMessageModel.DeliveryState {
        get { props.deliveryState }
    }
    public var message: SingleCypherMessage {
        get { props.message }
    }
    public var senderUser: Username {
        get { props.senderUser }
    }
    public var senderDeviceId: DeviceId {
        get { props.senderDeviceId }
    }
    
    @discardableResult
    func transitionDeliveryState(to newState: ChatMessageModel.DeliveryState) async throws -> MarkMessageResult {
        var state = self.deliveryState
        let result = state.transition(to: newState)
        try await setProp(at: \.deliveryState, to: state)
        return result
    }
}

@available(macOS 12, iOS 15, *)
public final class JobModel: Model {
    public struct SecureProps: Codable {
        private enum CodingKeys: String, CodingKey {
            case taskKey = "a"
            case task = "b"
            case delayedUntil = "c"
            case scheduledAt = "d"
            case attempts = "e"
            case isBackgroundTask = "f"
        }
        
        let taskKey: String
        var task: Document
        var delayedUntil: Date?
        var scheduledAt: Date
        var attempts: Int
        let isBackgroundTask: Bool
        
        init<T: Task>(task: T) throws {
            self.taskKey = task.key.rawValue
            self.isBackgroundTask = task.isBackgroundTask
            self.task = try BSONEncoder().encode(task)
            self.scheduledAt = Date()
            self.attempts = 0
        }
    }
    
    // The concrete type is used to avoid collision with Identifiable
    public let id: UUID
    public var props: Encrypted<SecureProps>
    
    public init(id: UUID, props: Encrypted<SecureProps>) {
        self.id = id
        self.props = props
    }
    
    internal init(props: SecureProps, encryptionKey: SymmetricKey) throws {
        self.id = UUID()
        self.props = try Encrypted(props, encryptionKey: encryptionKey)
    }
}

extension DecryptedModel where M == JobModel {
    public var taskKey: String {
        get { props.taskKey }
    }
    public var task: Document {
        get { props.task }
    }
    public var delayedUntil: Date? {
        get { props.delayedUntil }
    }
    public var scheduledAt: Date {
        get { props.scheduledAt }
    }
    public var attempts: Int {
        get { props.attempts }
    }
    public var isBackgroundTask: Bool {
        get { props.isBackgroundTask }
    }
    func delayExecution(retryDelay: TimeInterval) async throws {
        try await setProp(at: \.delayedUntil, to: Date().addingTimeInterval(retryDelay))
        try await setProp(at: \.attempts, to: self.attempts + 1)
    }
}
