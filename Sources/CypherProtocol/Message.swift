import BSON
import Foundation
import Crypto

public struct MultiRecipientContainer: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case signature = "b"
    }
    
    let message: Data
    let signature: Data
    
    public func readAndValidateData(
        usingIdentity identity: PublicSigningKey,
        decryptingWith key: SymmetricKey
    ) throws -> Data {
        try identity.validateSignature(signature, forData: message)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: message), using: key)
    }
    
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
    public let keys: [ContainerKey]
    
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

enum CypherMesageTag: String, Codable {
    case privateMessage = "a"
    case multiRecipientMessage = "b"
}

public struct RatchetedCypherMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag = "_"
        case message = "a"
        case signature = "b"
        case rekey = "c"
    }
    
    private(set) var tag: CypherMesageTag?
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
    
    public func readAndValidate(usingIdentity identity: PublicSigningKey) throws -> RatchetMessage {
        try identity.validateSignature(signature, forData: message)
        return try BSONDecoder().decode(RatchetMessage.self, from: Document(data: message))
    }
}

extension RatchetMessage {
    public func decrypt<D: Decodable, Hash: HashFunction>(
        as type: D.Type,
        using engine: inout DoubleRatchetHKDF<Hash>
    ) throws -> D {
        let data = try engine.ratchetDecrypt(self)
        return try BSONDecoder().decode(type, from: Document(data: data))
    }
    
    public init<E: Encodable, Hash: HashFunction>(
        encrypting value: E,
        using engine: inout DoubleRatchetHKDF<Hash>
    ) throws {
        let document = try BSONEncoder().encode(value)
        self = try engine.ratchetEncrypt(document.makeData())
    }
}
