import Foundation
import Crypto

public protocol MetadataProps {
    var metadata: Document { get set }
}

public protocol Model: Codable {
    associatedtype SecureProps: Codable
    
    var id: UUID { get }
    var props: Encrypted<SecureProps> { get set }
//    func setProps(to props: Encrypted<SecureProps>) async
    
//    func save(on store: CypherMessengerStore) async throws
}

// TODO: Re-enable cache, and reuse the cache globally
public final class DecryptedModel<M: Model> {
    private let lock = NSLock()
    public let encrypted: M
    public var id: UUID { encrypted.id }
    public private(set) var props: M.SecureProps
    private let encryptionKey: SymmetricKey
    
    public func withLock<T>(_ run: () async throws -> T) async rethrows -> T {
        lock.lock()
        do {
            let result = try await run()
            lock.unlock()
            return result
        } catch {
            lock.unlock()
            throw error
        }
    }
    
    @CryptoActor
    public func withProps<T>(get: (M.SecureProps) async throws -> T) async throws -> T {
        let props = try encrypted.props.decrypt(using: encryptionKey)
        return try await get(props)
    }
    
    @CryptoActor
    public func modifyProps<T>(run: (inout M.SecureProps) async throws -> T) async throws -> T {
        let value = try await run(&props)
        try await encrypted.props.update(to: props, using: encryptionKey)
        return value
    }
    
    @CryptoActor
    public func setProp<T>(at keyPath: WritableKeyPath<M.SecureProps, T>, to value: T) async throws {
        try await modifyProps { props in
            props[keyPath: keyPath] = value
        }
    }
    
    init(model: M, encryptionKey: SymmetricKey) async throws {
        self.encrypted = model
        self.encryptionKey = encryptionKey
        self.props = try await model.props.decrypt(using: encryptionKey)
    }
}
