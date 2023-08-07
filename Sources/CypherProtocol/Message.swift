import BSON
import Foundation
import Crypto

/// A container representing signed and encrypted data.
///
/// This container is used to store the message sent in a `MultiRecipientCypherMessage`.
public struct MultiRecipientContainer: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case signature = "b"
    }
    
    let message: Data
    let signature: Data
    
    /// Decrypts  the message and verifies it's signature
    public func readAndValidateData(
        usingIdentity identity: PublicSigningKey,
        decryptingWith key: SymmetricKey
    ) throws -> Data {
        try identity.validateSignature(signature, forData: message)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: message), using: key)
    }
    
    /// Decrypts the message and verifies it's signature, then decodes the value assuming the contents are BSON.
    public func readAndValidate<C: Codable>(
        type: C.Type,
        usingIdentity identity: PublicSigningKey,
        decryptingWith key: SymmetricKey
    ) throws -> C {
        try identity.validateSignature(signature, forData: message)
        let decrypted = try AES.GCM.open(AES.GCM.SealedBox(combined: message), using: key)
        return try BSONDecoder().decode(C.self, from: Document(data: decrypted))
    }
}

/// A single message with many recipients that supports end-to-end encryption.
///
/// A MultiRecipientMessage, also called MRM, has multiple recipients with a shared content.
/// MRMs can share large data blobs efficiently with many recipients, by sharing the message's encryption key individually with each party.
/// This allows each party to decrypt the message **and** to maintain efficiency in an end-to-end encrypted conversation.
///
/// This message type is the foundation of Multi-Device Support and end-to-end encrypted group chats.
public struct MultiRecipientCypherMessage: Codable {
    public struct ContainerKey: Codable {
        private enum CodingKeys: String, CodingKey {
            case user = "a"
            case deviceId = "b"
            case message = "c"
        }
        
        public let user: Username
        public let deviceId: DeviceId
        public let message: RatchetedCypherMessage
        
        public init(user: Username, deviceId: DeviceId, message: RatchetedCypherMessage) {
            self.user = user
            self.deviceId = deviceId
            self.message = message
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case tag = "_"
        case container = "a"
        case keys = "b"
    }
    
    private(set) var tag: CypherMesageTag?
    public let container: MultiRecipientContainer
    public var keys: [ContainerKey]
    
    public init(
        encryptedMessage: Data,
        signWith identity: PrivateSigningKey,
        keys: [ContainerKey]
    ) throws {
        self.tag = .multiRecipientMessage
        self.container = MultiRecipientContainer(
            message: encryptedMessage,
            signature: try identity.signature(for: encryptedMessage)
        )
        self.keys = keys
    }
}

/// A tag that can be used to quickly identify the type of message being sent
enum CypherMesageTag: String, Codable {
    case privateMessage = "a"
    case multiRecipientMessage = "b"
}

/// An end-to-end encrypted & signed blob targeting a single recipient
/// More performant than a MultiRecipientMesasge, but far less efficient for use in multi-recipient scenarios.
public struct RatchetedCypherMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag = "_"
        case message = "a"
        case signature = "b"
        case rekey = "c"
    }
    
    private(set) var tag: CypherMesageTag
    private let message: Data
    private let signature: Data
    
    // If `true`, the conversation needs to be re-encrypted with a new ratchet engine
    // Rekey must be sent as part of the first message of a new converstion
    // If the other party has no history, and rekey is set, the handshake is done
    // If the other party has a history (and thus has a key), the handshake is redone and the chat is unverified
    // If the other party sees no `rekey == true` and the data cannot be decrypted, the user gets the choice to rekey
    public let rekey: Bool
    
    public init(
        message: RatchetMessage,
        signWith identity: PrivateSigningKey,
        rekey: Bool
    ) throws {
        self.tag = .privateMessage
        self.message = try BSONEncoder().encode(message).makeData()
        self.signature = try identity.signature(for: self.message)
        self.rekey = rekey
    }
    
    /// Reads the contents as an end-to-end encrypted message, and verifies the signature.
    ///
    /// - Returns: A `RatchetMessage` that can be decrypted using the recipient's `DefaultRatchetHKDF`
    public func readAndValidate(usingIdentity identity: PublicSigningKey) throws -> RatchetMessage {
        try identity.validateSignature(signature, forData: message)
        return try BSONDecoder().decode(RatchetMessage.self, from: Document(data: message))
    }
}

extension RatchetMessage {
    public func decrypt<D: Decodable, Hash: HashFunction>(
        as type: D.Type,
        using engine: inout DoubleRatchetHKDF<Hash>
    ) throws -> D? {
        switch try engine.ratchetDecrypt(self) {
        case .success(let data):
            return try BSONDecoder().decode(type, from: Document(data: data))
        case .keyExpiry:
            return nil
        }
    }
    
    public init<E: Encodable, Hash: HashFunction>(
        encrypting value: E,
        using engine: inout DoubleRatchetHKDF<Hash>
    ) throws {
        let document = try BSONEncoder().encode(value)
        self = try engine.ratchetEncrypt(document.makeData())
    }
}
