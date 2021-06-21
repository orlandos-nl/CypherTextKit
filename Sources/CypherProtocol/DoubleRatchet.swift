// See: https://signal.org/docs/specifications/doubleratchet/#introduction
// TODO: Header encryption

import Foundation
import CryptoKit

/// A symmetric key encryption & decryption helper
public protocol RatchetSymmetricEncryption {
    /// Encrypts cleartext data symmetrically
    func encrypt<PlainText: DataProtocol, Nonce: DataProtocol>(_ data: PlainText, nonce: Nonce, usingKey: SymmetricKey) throws -> Data
    
    /// Decryptes cyphertext data into cleartext symmetrically
    func decrypt<CipherText: DataProtocol, Nonce: DataProtocol>(_ data: CipherText, nonce: Nonce, usingKey: SymmetricKey) throws -> Data
}

struct NonceMismatch: Error {}

/// A symmetric key encryption helper for AES-GCM
public struct AESGCMEncryption: RatchetSymmetricEncryption {
    public init() {}
    
    public func encrypt<PlainText, Nonce>(_ data: PlainText, nonce: Nonce, usingKey key: SymmetricKey) throws -> Data where PlainText : DataProtocol, Nonce : DataProtocol {
        try AES.GCM.seal(data, using: key).combined!
    }
    
    public func decrypt<CipherText, Nonce>(_ data: CipherText, nonce: Nonce, usingKey key: SymmetricKey) throws -> Data where CipherText : DataProtocol, Nonce : DataProtocol {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        
        return try AES.GCM.open(sealedBox, using: key)
    }
}

/// A symmetric key encryption helper for ChaChaPoly
public struct ChaChaPolyEncryption: RatchetSymmetricEncryption {
    public init() {}
    
    public func encrypt<PlainText, Nonce>(_ data: PlainText, nonce: Nonce, usingKey key: SymmetricKey) throws -> Data where PlainText : DataProtocol, Nonce : DataProtocol {
        try ChaChaPoly.seal(data, using: key).combined
    }
    
    public func decrypt<CipherText, Nonce>(_ data: CipherText, nonce: Nonce, usingKey key: SymmetricKey) throws -> Data where CipherText : DataProtocol, Nonce : DataProtocol {
        let sealedBox = try ChaChaPoly.SealedBox(combined: data)
        
        return try ChaChaPoly.open(sealedBox, using: key)
    }
}

/// Encodes & decodes a ratchet header into a lossless format
/// Can be used with Codable
public protocol RatchetHeaderEncoder {
    func encodeRatchetHeader(_ header: RatchetMessage.Header) throws -> Data
    func decodeRatchetHeader(from data: Data) throws -> RatchetMessage.Header
    func concatenate(authenticatedData: Data, withHeader header: Data) -> Data
}

/// A Key Derivation Function protocol that can calculate the (next) message's encryption key based on a created SymmetricKey
public protocol RatchetKDF {
    func calculateRootKey(diffieHellmanSecret: SharedSecret, rootKey: SymmetricKey) throws -> SymmetricKey
    func calculateChainKey(fromChainKey chainKey: SymmetricKey) throws -> SymmetricKey
    func calculateMessageKey(fromChainKey chainKey: SymmetricKey) throws -> SymmetricKey
}

/// A default symmetric key derivation function based on `HKDF` and a specified `HashFunction`
public struct DefaultRatchetKDF<Hash: HashFunction>: RatchetKDF {
    fileprivate let messageKeyConstant: Data
    fileprivate let chainKeyConstant: Data
    fileprivate let sharedInfo: Data
    
    public init(
        messageKeyConstant: Data,
        chainKeyConstant: Data,
        sharedInfo: Data
    ) {
        self.messageKeyConstant = messageKeyConstant
        self.chainKeyConstant = chainKeyConstant
        self.sharedInfo = sharedInfo
    }
    
    public func calculateRootKey(diffieHellmanSecret: SharedSecret, rootKey: SymmetricKey) throws -> SymmetricKey {
        diffieHellmanSecret.hkdfDerivedSymmetricKey(
            using: Hash.self,
            salt: rootKey.withUnsafeBytes { buffer in
                Data(buffer: buffer.bindMemory(to: UInt8.self))
            },
            sharedInfo: sharedInfo,
            outputByteCount: 32
        )
    }
    
    public func calculateChainKey(fromChainKey chainKey: SymmetricKey) throws -> SymmetricKey {
        let chainKey = HMAC<Hash>.authenticationCode(for: chainKeyConstant, using: chainKey)
        return SymmetricKey(data: chainKey)
    }
    
    public func calculateMessageKey(fromChainKey chainKey: SymmetricKey) throws -> SymmetricKey {
        let messageKey = HMAC<Hash>.authenticationCode(for: messageKeyConstant, using: chainKey)
        return SymmetricKey(data: messageKey)
    }
}

/// An AssociatedData generator provides an opportunity for implementations to improve entropy, and complicate the process of finding the correct key.
///
/// It can be a constant shared piece of information, such as the app name. But could also be based on information known to one or both clients.
public struct RatchetAssociatedDataGenerator {
    private enum Mode {
        case constant(Data)
    }
    
    private let mode: Mode
    
    public static func constant<Raw: DataProtocol>(_ data: Raw) -> RatchetAssociatedDataGenerator {
        .init(mode: .constant(Data(data)))
    }
    
    func generateAssociatedData() -> Data {
        switch mode {
        case .constant(let data):
            return data
        }
    }
}

/// A configuration type that is used by the DoubleRatchet algorithm to encrypt and decrypt information.
/// Both the `sender` and `recipient` must share the same settings, consistently.
public struct DoubleRatchetConfiguration<Hash: HashFunction> {
    fileprivate let info: Data
    let symmetricEncryption: RatchetSymmetricEncryption
    let kdf: RatchetKDF
    let headerEncoder: RatchetHeaderEncoder
    let headerAssociatedDataGenerator: RatchetAssociatedDataGenerator
    let maxSkippedMessageKeys: Int
    
    /// - Parameters:
    ///     - info: A shared piece of information, such as protocol or app name
    ///     - symmetricEncryption: A symmmetric key encryption/decryption algorithm
    ///     - kdf: A Key Derivation Function that derives the next encryption key in chain
    ///     - headerEncoder: Encodes the RatchetHeader into `Data`
    ///     - headerAssociatedDataGenerator: A generator that can add entropy to the key generation process
    ///     - maxSkippedMessageKeys; The amount of messages that can be sent out-of-order before the message cannot be decrypted anymore.
    public init<Info: DataProtocol>(
        info: Info,
        symmetricEncryption: RatchetSymmetricEncryption,
        kdf: RatchetKDF,
        headerEncoder: RatchetHeaderEncoder,
        headerAssociatedDataGenerator: RatchetAssociatedDataGenerator,
        maxSkippedMessageKeys: Int
    ) {
        self.info = Data(info)
        self.symmetricEncryption = symmetricEncryption
        self.kdf = kdf
        self.headerEncoder = headerEncoder
        self.headerAssociatedDataGenerator = headerAssociatedDataGenerator
        self.maxSkippedMessageKeys = maxSkippedMessageKeys
    }
}

extension SymmetricKey: Codable {
    public func encode(to encoder: Encoder) throws {
        let data = self.withUnsafeBytes { buffer in
            Data(buffer: buffer.bindMemory(to: UInt8.self))
        }
        
        try data.encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        let data = try Data(from: decoder)
        self.init(data: data)
    }
}

/// A skipped key is a generated key which no valid message has been received for.
/// This may be a message that was sent out of order, and thus is yet to be received.
public struct SkippedKey: Codable {
    private enum CodingKeys: String, CodingKey {
        case publicKey = "a"
        case messageIndex = "b"
        case messageKey = "c"
    }
    
    let publicKey: PublicKey
    let messageIndex: Int
    let messageKey: SymmetricKey
}

public struct DoubleRatchetHKDF<Hash: HashFunction> {
    public struct State: Codable {
        private enum CodingKeys: String, CodingKey {
            case rootKey = "a"
            case localPrivateKey = "b"
            case remotePublicKey = "c"
            case sendingKey = "d"
            case receivingKey = "e"
            case previousMessages = "f"
            case sentMessages = "g"
            case receivedMessages = "h"
            case skippedKeys = "i"
        }
        
        // `RK`
        public fileprivate(set) var rootKey: SymmetricKey
        
        // `DHs`
        public fileprivate(set) var localPrivateKey: PrivateKey
        
        // `DHr`
        public fileprivate(set) var remotePublicKey: PublicKey?
        
        // `CKs`
        public fileprivate(set) var sendingKey: SymmetricKey?
        
        // `CKr`
        public fileprivate(set) var receivingKey: SymmetricKey?
        
        // `PN`
        public fileprivate(set) var previousMessages: Int
        
        // `Ns`
        public fileprivate(set) var sentMessages: Int
        
        // `Nr`
        public fileprivate(set) var receivedMessages: Int
        
        public fileprivate(set) var skippedKeys = [SkippedKey]()
        
        fileprivate init(
            secretKey: SymmetricKey,
            contactingRemote remote: PublicKey,
            configuration: DoubleRatchetConfiguration<Hash>
        ) throws {
            guard secretKey.bitCount == 256 else {
                throw DoubleRatchetError.invalidRootKeySize
            }
            
            let localPrivateKey = PrivateKey()
            let rootKey = try configuration.kdf.calculateRootKey(
                diffieHellmanSecret: localPrivateKey.sharedSecretFromKeyAgreement(with: remote),
                rootKey: secretKey
            )
            
            self.localPrivateKey = localPrivateKey
            self.rootKey = rootKey
            self.remotePublicKey = remote
            self.sendingKey = try configuration.kdf.calculateChainKey(fromChainKey: rootKey)
            self.receivingKey = nil
            
            self.previousMessages = 0
            self.sentMessages = 0
            self.receivedMessages = 0
        }
        
        fileprivate init(
            secretKey: SymmetricKey,
            localPrivateKey: PrivateKey,
            configuration: DoubleRatchetConfiguration<Hash>
        ) throws {
            guard secretKey.bitCount == 256 else {
                throw DoubleRatchetError.invalidRootKeySize
            }
            
            self.rootKey = secretKey
            self.localPrivateKey = localPrivateKey
            self.remotePublicKey = nil
            self.sendingKey = nil
            self.receivingKey = nil
            
            self.previousMessages = 0
            self.sentMessages = 0
            self.receivedMessages = 0
        }
    }
    
    public private(set) var state: State
    public let configuration: DoubleRatchetConfiguration<Hash>
    
    /// Creates an 'engine', capable of encryption and decryption, by resuming a saved `state.
    ///
    /// - Parameters:
    ///     - state: The state to resume
    ///     - configuration: Settings that match the exact behaviour of the other party
    public init(
        state: State,
        configuration: DoubleRatchetConfiguration<Hash>
    ) {
        self.state = state
        self.configuration = configuration
    }
    
    /// Creates a new ratchet conversation with a remote party.
    ///
    /// The remote party _must_ initialise their communications using `initializeRecipient
    ///
    /// - Parameters:
    ///     - secretKey: The shared secret that was created by, for example, a Diffie-Hellman handshake
    ///     - contactingRemote: The remote party's publicKey, used as the first publicKey for forward secrecy
    ///     - configuration: Settings that match the exact behaviour of the other party
    ///
    /// - Returns: The DoubleRatchetHKDF engine, that can be used to send and receive messages
    public static func initializeSender(
        secretKey: SymmetricKey,
        contactingRemote remote: PublicKey,
        configuration: DoubleRatchetConfiguration<Hash>
    ) throws -> DoubleRatchetHKDF<Hash> {
        let state = try State(
            secretKey: secretKey,
            contactingRemote: remote,
            configuration: configuration
        )
        return DoubleRatchetHKDF<Hash>(state: state, configuration: configuration)
    }
    
    /// Accepts a new ratchet conversation created a remote party.
    ///
    /// The remote party has initialise their communications using `initializeSender`
    ///
    /// - Parameters:
    ///     - secretKey: The shared secret that was created by, for example, a Diffie-Hellman handshake
    ///     - localPrivateKey: Our first privateKey used for forwardSecrecy
    ///     - configuration: Settings that match the exact behaviour of the other party
    ///     - initialMessage: The first message that was sent by the `sender`
    ///
    /// - Returns: The DoubleRatchetHKDF engine, that can be used to send and receive messages; the first message sent by the remote party
    public static func initializeRecipient(
        secretKey: SymmetricKey,
        localPrivateKey: PrivateKey,
        configuration: DoubleRatchetConfiguration<Hash>,
        initialMessage: RatchetMessage
    ) throws -> (DoubleRatchetHKDF<Hash>, Data) {
        let state = try State(secretKey: secretKey, localPrivateKey: localPrivateKey, configuration: configuration)
        var engine = DoubleRatchetHKDF<Hash>(state: state, configuration: configuration)
        let plaintext = try engine.ratchetDecrypt(initialMessage)
        return (engine, plaintext)
    }
    
    /// Encrypts a new cleartext message
    ///
    /// The result is decrypted by the other party using `ratchetDecrypt`
    ///
    /// - Returns: The encrypted `RatchetMessage`
    public mutating func ratchetEncrypt<PlainText: DataProtocol>(_ plaintext: PlainText) throws -> RatchetMessage {
        guard let sendingKey = state.sendingKey else {
            throw DoubleRatchetError.uninitializedRecipient
        }
        
        // state.CKs, mk = KDF_CK(state.CKs)
        let messageKey = try configuration.kdf.calculateMessageKey(fromChainKey: sendingKey)
        state.sendingKey = try configuration.kdf.calculateChainKey(fromChainKey: sendingKey)
        
        // header = HEADER(state.DHs, state.PN, state.Ns)
        let header = RatchetMessage.Header(
            senderPublicKey: state.localPrivateKey.publicKey,
            previousChainLength: state.previousMessages,
            messageNumber: state.sentMessages
        )
        let headerData = try configuration.headerEncoder.encodeRatchetHeader(header)
        let nonce = configuration.headerEncoder.concatenate(
            authenticatedData: configuration.headerAssociatedDataGenerator.generateAssociatedData(),
            withHeader: headerData
        )
        
        guard nonce.count == 32 else {
            throw DoubleRatchetError.invalidNonceLength
        }
        
        // state.Ns += 1
        state.sentMessages += 1
        
        // return header, ENCRYPT(mk, plaintext, CONCAT(AD, header))
        let ciphertext = try configuration.symmetricEncryption.encrypt(plaintext, nonce: nonce, usingKey: messageKey)
        return RatchetMessage(
            header: header,
            ciphertext: ciphertext
        )
    }
    
    /// Decrypts a new `RatchetMessage` message as `Data`
    ///
    /// The message used as input _must_ be created by the remote party `ratchetEncrypt`
    ///
    /// - Returns: The decrypted data
    public mutating func ratchetDecrypt(_ message: RatchetMessage) throws -> Data {
        var skippedKeys = state.skippedKeys
        defer {
            state.skippedKeys = skippedKeys
        }
        func skipMessageKeys(until keyIndex: Int) throws {
            guard let receivingKey = state.receivingKey else {
                return
            }
            
            while state.receivedMessages < keyIndex {
                let messageKey = try configuration.kdf.calculateMessageKey(fromChainKey: receivingKey)
                state.receivingKey = try configuration.kdf.calculateChainKey(fromChainKey: receivingKey)
                skippedKeys.append(
                    SkippedKey(
                        publicKey: message.header.senderPublicKey,
                        messageIndex: state.receivedMessages,
                        messageKey: messageKey
                    )
                )
                
                if skippedKeys.count > self.configuration.maxSkippedMessageKeys {
                    skippedKeys.removeFirst()
                }
                
                state.receivedMessages += 1
            }
        }
        
        func decodeUsingSkippedMessageKeys() throws -> Data? {
            for i in 0..<skippedKeys.count {
                let skippedKey = skippedKeys[i]
                
                if skippedKey.messageIndex == message.header.messageNumber && message.header.senderPublicKey == skippedKey.publicKey {
                    skippedKeys.remove(at: i)
                    
                    return try decryptMessage(message, usingKey: skippedKey.messageKey)
                }
            }
            
            return nil
        }
        
        func diffieHellmanRatchet() throws {
            state.previousMessages = state.sentMessages
            state.sentMessages = 0
            state.receivedMessages = 0
            state.remotePublicKey = message.header.senderPublicKey
            
            state.rootKey = try configuration.kdf.calculateRootKey(
                diffieHellmanSecret: state.localPrivateKey.sharedSecretFromKeyAgreement(with: message.header.senderPublicKey),
                rootKey: state.rootKey
            )
            state.receivingKey = try configuration.kdf.calculateChainKey(fromChainKey: state.rootKey)
            state.localPrivateKey = PrivateKey()
            
            state.rootKey = try configuration.kdf.calculateRootKey(
                diffieHellmanSecret: state.localPrivateKey.sharedSecretFromKeyAgreement(with: message.header.senderPublicKey),
                rootKey: state.rootKey
            )
            state.sendingKey = try configuration.kdf.calculateChainKey(fromChainKey: state.rootKey)
        }
        
        // 1. Try skipped message keys
        if let plaintext = try decodeUsingSkippedMessageKeys() {
            return plaintext
        }
        
        // 2. Check if the publicKey matches the current key
        if message.header.senderPublicKey != state.remotePublicKey {
            // It seems that the key is out of date, so it should be replaced
            try skipMessageKeys(until: message.header.previousChainLength)
            state.skippedKeys = skippedKeys
            try diffieHellmanRatchet()
        }
        
        // 3.a. On-mismatch, Skip ahead in message keys until max. Store all the inbetween message keys in a history
        try skipMessageKeys(until: message.header.messageNumber)
        state.skippedKeys = skippedKeys
        
        guard let receivingKey = state.receivingKey else {
            preconditionFailure("Somehow, the DHRatchet wasn't executed although the receivingKey was `nil`")
        }
        
        let messageKey = try configuration.kdf.calculateMessageKey(fromChainKey: receivingKey)
        state.receivingKey = try configuration.kdf.calculateChainKey(fromChainKey: receivingKey)
        state.receivedMessages += 1
        
        return try decryptMessage(message, usingKey: messageKey)
    }
    
    private func decryptMessage(_ message: RatchetMessage, usingKey messageKey: SymmetricKey) throws -> Data {
        let headerData = try configuration.headerEncoder.encodeRatchetHeader(message.header)
        let nonce = configuration.headerEncoder.concatenate(
            authenticatedData: configuration.headerAssociatedDataGenerator.generateAssociatedData(),
            withHeader: headerData
        )
        
        guard nonce.count == 32 else {
            throw DoubleRatchetError.invalidNonceLength
        }
        
        return try configuration.symmetricEncryption.decrypt(
            message.ciphertext,
            nonce: nonce,
            usingKey: messageKey
        )
    }
}

public struct RatchetMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case header = "a"
        case ciphertext = "b"
    }
    
    public struct Header: Codable {
        private enum CodingKeys: String, CodingKey {
            case senderPublicKey = "a"
            case previousChainLength = "b"
            case messageNumber = "c"
        }
        
        // `dh_pair`
        let senderPublicKey: PublicKey
        
        // `pn`
        let previousChainLength: Int
        
        // `N`
        let messageNumber: Int
    }
    
    let header: Header
    let ciphertext: Data
}

enum DoubleRatchetError: Error {
    case invalidRootKeySize, uninitializedRecipient, tooManySkippedMessages, invalidNonceLength
}
