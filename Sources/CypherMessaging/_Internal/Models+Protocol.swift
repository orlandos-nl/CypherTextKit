import Foundation
import Crypto

public protocol MetadataProps {
    var metadata: Document { get set }
}

public protocol Model: Codable, Sendable {
    associatedtype SecureProps: Codable & Sendable
    
    var id: UUID { get }
    var props: Encrypted<SecureProps> { get }
}

// TODO: Re-enable cache, and reuse the cache globally
public final class DecryptedModel<M: Model>: @unchecked Sendable {
    public let encrypted: M
    public var id: UUID { encrypted.id }
    @MainActor public private(set) var props: M.SecureProps
    private let encryptionKey: SymmetricKey
    
    @MainActor
    public func withProps<T>(get: @Sendable (M.SecureProps) async throws -> T) async throws -> T {
        let props = try encrypted.props.decrypt(using: encryptionKey)
        return try await get(props)
    }
    
    @MainActor
    public func modifyProps<T>(run: @MainActor @Sendable (inout M.SecureProps) throws -> T) throws -> T {
        let value = try run(&props)
        try encrypted.props.update(to: props, using: encryptionKey)
        return value
    }
    
    @MainActor
    public func setProp<T>(at keyPath: WritableKeyPath<M.SecureProps, T>, to value: T) throws {
        try modifyProps { props in
            props[keyPath: keyPath] = value
        }
    }
    
    @MainActor
    init(model: M, encryptionKey: SymmetricKey) throws {
        self.encrypted = model
        self.encryptionKey = encryptionKey
        self.props = try model.props.decrypt(using: encryptionKey)
    }
}

internal final class _DecryptedModel<M: Model>: @unchecked Sendable {
    internal let encrypted: M
    internal var id: UUID { encrypted.id }
    @CryptoActor public private(set) var props: M.SecureProps
    private let encryptionKey: SymmetricKey
    
    @CryptoActor
    internal func withProps<T>(get: @Sendable (M.SecureProps) async throws -> T) async throws -> T {
        let props = try encrypted.props.decrypt(using: encryptionKey)
        return try await get(props)
    }
    
    @CryptoActor
    internal func modifyProps<T>(run: @CryptoActor @Sendable (inout M.SecureProps) throws -> T) throws -> T {
        let value = try run(&props)
        try encrypted.props.update(to: props, using: encryptionKey)
        return value
    }
    
    @CryptoActor
    internal func setProp<T: Sendable>(at keyPath: WritableKeyPath<M.SecureProps, T>, to value: T) throws {
        try modifyProps { props in
            props[keyPath: keyPath] = value
        }
    }
    
    @CryptoActor
    init(model: M, encryptionKey: SymmetricKey) throws {
        self.encrypted = model
        self.encryptionKey = encryptionKey
        self.props = try model.props.decrypt(using: encryptionKey)
    }
}
