import NIOFoundationCompat
import BSON
import NIO
import Foundation
import CryptoKit

typealias HashFunctionAlg = SHA256
typealias PrivateSigningKeyAlg = Curve25519.Signing.PrivateKey
typealias PublicSigningKeyAlg = Curve25519.Signing.PublicKey
typealias PrivateKeyAgreementKeyAlg = Curve25519.KeyAgreement.PrivateKey
typealias PublicKeyAgreementKeyAlg = Curve25519.KeyAgreement.PublicKey

enum CypherProtocolError: Error {
    case invalidSignature
}

public struct PrivateSigningKey: Codable {
    fileprivate let privateKey: PrivateSigningKeyAlg
    
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
    
    public func signature<D: DataProtocol>(for data: D) throws -> Data {
        return try privateKey.signature(for: data)
    }
}

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
    
    public var data: Data {
        publicKey.rawRepresentation
    }
    
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

public struct PrivateKey: Codable {
    fileprivate let privateKey: PrivateKeyAgreementKeyAlg
    
    public var publicKey: PublicKey {
        PublicKey(publicKey: privateKey.publicKey)
    }
    
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
    
    public func sharedSecretFromKeyAgreement(with publicKey: PublicKey) throws -> SharedSecret {
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey.publicKey)
    }
}

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
    
    public func sign(using identity: PrivateSigningKey) throws -> Signed<PublicKey> {
        try Signed(self, signedBy: identity)
    }
}

/// This publicKey can be used to contact it's owner and exchange a shared secret for communication
/// Once contact is established, it can be safely replaced as both ends now know the shared secret
public struct Signed<T: Codable>: Codable {
    public let value: Document
    public let signature: Data
    
    public init(_ value: T, signedBy identity: PrivateSigningKey) throws {
        self.value = try BSONEncoder().encode(value)
        self.signature = try identity.signature(for: self.value.makeData())
    }
    
    public func verifySignature(signedBy publicIdentity: PublicSigningKey) throws {
        try publicIdentity.validateSignature(
            signature,
            forData: value.makeData()
        )
    }
    
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
    
    public func readAndVerifySignature(signedBy publicIdentity: PublicSigningKey) throws -> T {
        try publicIdentity.validateSignature(
            signature,
            forData: value.makeData()
        )
        
        return try BSONDecoder().decode(T.self, from: value)
    }
    
    public func readWithoutVerifying() throws -> T {
        return try BSONDecoder().decode(T.self, from: value)
    }
}
