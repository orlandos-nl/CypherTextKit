import NIOFoundationCompat
import BSON
import NIO
import Foundation
import Crypto

typealias PrivateSigningKeyAlg = Curve25519.Signing.PrivateKey
typealias PublicSigningKeyAlg = Curve25519.Signing.PublicKey
typealias PrivateKeyAgreementKeyAlg = Curve25519.KeyAgreement.PrivateKey
typealias PublicKeyAgreementKeyAlg = Curve25519.KeyAgreement.PublicKey

enum CypherProtocolError: Error {
    case invalidSignature
}

/// A wrapper around Curve25519 private _signing_ keys that provides Codable support using `Foundation.Data`
///
/// Private keys are used to sign data, as to authenticate that it was sent by the owner of this private key.
/// The `publicKey` can be shared, and can then be used to verify the signature's validity.
public struct PrivateSigningKey: Codable {
    fileprivate let privateKey: PrivateSigningKeyAlg
    
    /// The public key that can verify signatures of this private key, wrapped in a Codable container.
    public var publicKey: PublicSigningKey {
        PublicSigningKey(publicKey: privateKey.publicKey)
    }
    
    public init() {
        self.privateKey = .init()
    }
    
    public func encode(to encoder: Encoder) throws {
        try privateKey.rawRepresentation.encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        privateKey = try .init(rawRepresentation: Data(from: decoder))
    }
    
    ///
    public func signature<D: DataProtocol>(for data: D) throws -> Data {
        return try privateKey.signature(for: data)
    }
}

/// A wrapper around Curve25519 public _signing_ keys that provides Codable support using `Foundation.Data`
///
/// Public signing keys are used to verify signatures by the matching private key.
public struct PublicSigningKey: Codable {
    fileprivate let publicKey: PublicSigningKeyAlg
    
    fileprivate init(publicKey: PublicSigningKeyAlg) {
        self.publicKey = publicKey
    }
    
    public func encode(to encoder: Encoder) throws {
        try Binary(buffer: ByteBuffer(data: publicKey.rawRepresentation)).encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        do {
            publicKey = try .init(rawRepresentation: Binary(from: decoder).data)
        } catch {
            do {
                publicKey = try .init(rawRepresentation: Data(from: decoder))
            } catch {
                publicKey = try .init(rawRepresentation: Data([UInt8](from: decoder)))
            }
        }
    }
    
    /// Represents the raw data of this public key
    public var data: Data {
        publicKey.rawRepresentation
    }
    
    /// Verifies that the signature was created by the private key that spawned this public key.
    ///
    /// - Parameters:
    ///     - signature: The signature to be verified
    ///     - data: The data that this signature was created for
    ///
    /// - Throws: `CypherProtocolError.invalidSignature` if the signature was not correct
    public func validateSignature<
        Signature: DataProtocol,
        D: DataProtocol
    >(
        _ signature: Signature,
        forData data: D
    ) throws {
        guard publicKey.isValidSignature(signature, for: data) else {
            throw CypherProtocolError.invalidSignature
        }
    }
}

/// A wrapper around Curve25519 private keys that provides Codable support using `Foundation.Data`
///
/// This Private Key type is used for handshakes, to establish a shared secret key over unsafe communication channels.
public struct PrivateKey: Codable {
    fileprivate let privateKey: PrivateKeyAgreementKeyAlg
    
    /// Derives a `PublicKey` that can be sent to a third party.
    ///
    /// If they derive a secret with their `PrivateKey` with this `PublicKey`, they'll find the same secret as our `PrivateKey` would with their `PublicKey`.
    /// This communicates a secret without being vulnerable to eavesdroppers.
    public var publicKey: PublicKey {
        PublicKey(publicKey: privateKey.publicKey)
    }
    
    /// Generate a new private key
    public init() {
        self.privateKey = .init()
    }
    
    public func encode(to encoder: Encoder) throws {
        try Binary(buffer: ByteBuffer(data: privateKey.rawRepresentation)).encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        do {
            privateKey = try .init(rawRepresentation: Binary(from: decoder).data)
        } catch {
            do {
                privateKey = try .init(rawRepresentation: Data(from: decoder))
            } catch {
                privateKey = try .init(rawRepresentation: Data([UInt8](from: decoder)))
            }
        }
    }
    
    /// Derives a shared secret by combining our `PrivateKey` with a remote's `PublicKey`.
    ///
    /// If they derive a secret with their `PrivateKey` with this `PublicKey`, they'll find the same secret as our `PrivateKey` would with their `PublicKey`.
    /// This communicates a secret without being vulnerable to eavesdroppers.
    ///
    /// - Returns: A derives secret, known only to _you_ and _them_
    public func sharedSecretFromKeyAgreement(with publicKey: PublicKey) throws -> SharedSecret {
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey.publicKey)
    }
}

/// A key that is derived from `PrivateKey`.
/// Used to create a shared secret, known only to the owner of the PrivateKeys that shared their PublicKey.
public struct PublicKey: Codable, Equatable {
    fileprivate let publicKey: PublicKeyAgreementKeyAlg
    
    fileprivate init(publicKey: PublicKeyAgreementKeyAlg) {
        self.publicKey = publicKey
    }
    
    public func encode(to encoder: Encoder) throws {
        try publicKey.rawRepresentation.encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        publicKey = try .init(rawRepresentation: Data(from: decoder))
    }
    
    public static func ==(lhs: PublicKey, rhs: PublicKey) -> Bool {
        lhs.publicKey.rawRepresentation == rhs.publicKey.rawRepresentation
    }
    
    /// Signs this PublicKey using a SigningKey.
    ///
    /// By signing the public key with your signing key, the other party only needs to verify the validity of your public key.
    /// Doing so allows the remote party to safely use this PublicKey for establishing a shared secret.
    public func sign(using identity: PrivateSigningKey) throws -> Signed<PublicKey> {
        try Signed(self, signedBy: identity)
    }
}

/// A signed `Document` container that contains (unstructured) data.
///
/// Can be verified and unpacked using the correct publicKey, to verify it was sent by the expected origin.
public struct Signed<T: Codable>: Codable {
    public let value: Document
    public let signature: Data
    
    public init(_ value: T, signedBy identity: PrivateSigningKey) throws {
        self.value = try BSONEncoder().encode(value)
        self.signature = try identity.signature(for: self.value.makeData())
    }
    
    /// Verifies that the signature was created by `publicIdentity`.
    ///
    /// - Throws: `CypherProtocolError.invalidSignature` if the signature was not created by `publicIdentity`
    public func verifySignature(signedBy publicIdentity: PublicSigningKey) throws {
        try publicIdentity.validateSignature(
            signature,
            forData: value.makeData()
        )
    }
    
    /// Verifies that the signature was created by `publicIdentity`.
    public func isSigned(by publicIdentity: PublicSigningKey) -> Bool {
        do {
            try publicIdentity.validateSignature(
                signature,
                forData: value.makeData()
            )
            
            return true
        } catch {
            return false
        }
    }
    
    /// Reads the data, and verifies that it was sent by the creator of `publicIdentity`.
    public func readAndVerifySignature(signedBy publicIdentity: PublicSigningKey) throws -> T {
        try publicIdentity.validateSignature(
            signature,
            forData: value.makeData()
        )
        
        return try BSONDecoder().decode(T.self, from: value)
    }
    
    /// Reads the data without verifying the sender.
    public func readWithoutVerifying() throws -> T {
        return try BSONDecoder().decode(T.self, from: value)
    }
}
