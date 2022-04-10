import Crypto
import BSON
import Foundation
import CypherProtocol

public final class ConversationModel: Model, @unchecked Sendable {
    public struct SecureProps: Codable, @unchecked Sendable, MetadataProps {
        // TODO: Shorter CodingKeys
        
        public var members: Set<Username>
        public var kickedMembers: Set<Username>
        public var metadata: Document
        public var localOrder: Int
    }
    
    public let id: UUID
    
    public let props: Encrypted<SecureProps>
    
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
    @MainActor public var members: Set<Username> {
        get { props.members }
    }
    @MainActor public var kickedMembers: Set<Username> {
        get { props.kickedMembers }
    }
    @MainActor public var allHistoricMembers: Set<Username> {
        get {
            var members = members
            members.formUnion(kickedMembers)
            return members
        }
    }
    @MainActor public var metadata: Document {
        get { props.metadata }
    }
    @MainActor public var localOrder: Int {
        get { props.localOrder }
    }
    
    @CryptoActor func getNextLocalOrder() async throws -> Int {
        let order = await localOrder
        try await setProp(at: \.localOrder, to: order &+ 1)
        return order
   }
}

public final class DeviceIdentityModel: Model, @unchecked Sendable {
    public struct SecureProps: Codable, @unchecked Sendable {
        // TODO: Shorter CodingKeys
        
        let username: Username
        let deviceId: DeviceId
        let senderId: Int
        let publicKey: PublicKey
        let identity: PublicSigningKey
        let isMasterDevice: Bool
        var doubleRatchet: DoubleRatchetHKDF<SHA512>.State?
        var deviceName: String?
        
        // TODO: Verify identity on the server later when possible
        var serverVerified: Bool?
        var lastRekey: Date?
    }
    
    public let id: UUID

    public let props: Encrypted<SecureProps>
    
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

extension _DecryptedModel where M == DeviceIdentityModel {
    @CryptoActor var username: Username {
        get { props.username }
    }
    @CryptoActor var deviceId: DeviceId {
        get { props.deviceId }
    }
    @CryptoActor var isMasterDevice: Bool {
        get { props.isMasterDevice }
    }
    @CryptoActor var senderId: Int {
        get { props.senderId }
    }
    @CryptoActor var publicKey: PublicKey {
        get { props.publicKey }
    }
    @CryptoActor var identity: PublicSigningKey {
        get { props.identity }
    }
    @CryptoActor var doubleRatchet: DoubleRatchetHKDF<SHA512>.State? {
        get { props.doubleRatchet }
    }
    @CryptoActor var deviceName: String? {
        get { props.deviceName }
    }
    @CryptoActor func updateDoubleRatchetState(to newValue: DoubleRatchetHKDF<SHA512>.State?) throws {
        try setProp(at: \.doubleRatchet, to: newValue)
    }
    @CryptoActor func updateDeviceName(to newValue: String?) throws {
        try setProp(at: \.deviceName, to: newValue)
    }
}

public final class ContactModel: Model, @unchecked Sendable {
    public struct SecureProps: Codable, @unchecked Sendable, MetadataProps {
        // TODO: Shorter CodingKeys
        
        public let username: Username
        public internal(set) var config: UserConfig
        public var metadata: Document
    }
    
    public let id: UUID

    public let props: Encrypted<SecureProps>
    
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
    @MainActor public var username: Username {
        get { props.username }
    }
    @MainActor public var config: UserConfig {
        get { props.config }
    }
    @MainActor public var metadata: Document {
        get { props.metadata }
    }
    @CryptoActor func updateConfig(to newValue: UserConfig) async throws {
        try await self.setProp(at: \.config, to: newValue)
    }
}

public enum MarkMessageResult: Sendable {
    case success, error, notModified
}

@available(macOS 10.15, iOS 13, *)
public final class ChatMessageModel: Model, @unchecked Sendable {
    public enum DeliveryState: Int, Codable, Sendable {
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
    
    public struct SecureProps: Codable, @unchecked Sendable {
        private enum CodingKeys: String, CodingKey {
            case sendDate = "a"
            case receiveDate = "b"
            case deliveryState = "c"
            case message = "d"
            case senderUser = "e"
            case senderDeviceId = "f"
            case deliveryStates = "g"
        }
        
        public let sendDate: Date
        public let receiveDate: Date
        public internal(set) var deliveryState: DeliveryState
        public var message: SingleCypherMessage
        public let senderUser: Username
        public let senderDeviceId: DeviceId
        public internal(set) var deliveryStates: Document?
        
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
            self.deliveryStates = [:]
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
            self.deliveryStates = [:]
        }
    }
    
    // `id` must be unique, or rejected when saving
    public let id: UUID
    
    public let conversationId: UUID
    public let senderId: Int
    public let order: Int
    
    // `remoteId` must be unique, or rejected when saving
    public let remoteId: String
    
    public let props: Encrypted<SecureProps>
    
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

public struct DeliveryStates {
    var document: Document
    
    public subscript(username: Username) -> ChatMessageModel.DeliveryState {
        get {
            if
                let currentStateCode = document[username.raw] as? Int,
                let currentState = ChatMessageModel.DeliveryState(rawValue: currentStateCode)
            {
                return currentState
            } else {
                return .none
            }
        }
        set {
            document[username.raw] = newValue.rawValue
        }
    }
}

extension DecryptedModel where M == ChatMessageModel {
    @MainActor  public var sendDate: Date {
        get { props.sendDate }
    }
    @MainActor public var receiveDate: Date {
        get { props.receiveDate }
    }
    @MainActor public var deliveryState: ChatMessageModel.DeliveryState {
        get { props.deliveryState }
    }
    @MainActor var _deliveryStates: Document {
        get { props.deliveryStates ?? [:] }
    }
    @MainActor var deliveryStates: DeliveryStates {
        get { DeliveryStates(document: _deliveryStates) }
    }
    @MainActor public var message: SingleCypherMessage {
        get { props.message }
    }
    @MainActor public var senderUser: Username {
        get { props.senderUser }
    }
    @MainActor public var senderDeviceId: DeviceId {
        get { props.senderDeviceId }
    }
    
    @discardableResult
    @CryptoActor func transitionDeliveryState(to newState: ChatMessageModel.DeliveryState, forUser user: Username, messenger: CypherMessenger) async throws -> MarkMessageResult {
        if user != messenger.username {
            var state = await self.deliveryState
            let result = state.transition(to: newState)
            try await setProp(at: \.deliveryState, to: state)
        }
        
        var allStates = await self.deliveryStates
        allStates[user].transition(to: newState)
        try await setProp(at: \.deliveryStates, to: allStates.document)
        
        return result
    }
}

@available(macOS 10.15, iOS 13, *)
public final class JobModel: Model, @unchecked Sendable {
    public struct SecureProps: Codable, @unchecked Sendable {
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
        
        init<T: StoredTask>(task: T) throws {
            self.taskKey = task.key.rawValue
            self.isBackgroundTask = task.isBackgroundTask
            self.task = try BSONEncoder().encode(task)
            self.scheduledAt = Date()
            self.attempts = 0
        }
    }
    
    // The concrete type is used to avoid collision with Identifiable
    public let id: UUID
    public let props: Encrypted<SecureProps>
    
    public init(id: UUID, props: Encrypted<SecureProps>) {
        self.id = id
        self.props = props
    }
    
    internal init(props: SecureProps, encryptionKey: SymmetricKey) throws {
        self.id = UUID()
        self.props = try Encrypted(props, encryptionKey: encryptionKey)
    }
}

extension _DecryptedModel where M == JobModel {
    @CryptoActor var taskKey: String {
        get { props.taskKey }
    }
    @CryptoActor var task: Document {
        get { props.task }
    }
    @CryptoActor var delayedUntil: Date? {
        get { props.delayedUntil }
    }
    @CryptoActor var scheduledAt: Date {
        get { props.scheduledAt }
    }
    @CryptoActor var attempts: Int {
        get { props.attempts }
    }
    @CryptoActor var isBackgroundTask: Bool {
        get { props.isBackgroundTask }
    }
    @CryptoActor func delayExecution(retryDelay: TimeInterval) throws {
        try setProp(at: \.delayedUntil, to: Date().addingTimeInterval(retryDelay))
        try setProp(at: \.attempts, to: self.attempts + 1)
    }
}
