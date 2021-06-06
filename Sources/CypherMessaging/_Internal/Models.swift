import Crypto
import BSON
import Foundation
import CypherProtocol

public final class ConversationModel: Model {
    public struct SecureProps: Codable {
        public var members: Set<Username>
        public var metadata: Document
        public var localOrder: Int
        
        mutating func getNextLocalOrder() -> Int {
            defer { localOrder += 1 }
            return localOrder
        }
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

public enum MarkMessageResult {
    case success, error, notModified
}

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
