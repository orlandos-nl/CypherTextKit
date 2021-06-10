import Foundation
import Crypto

public protocol Model: Codable {
    associatedtype SecureProps: Codable
    
    var id: UUID { get }
    var props: Encrypted<SecureProps> { get set }
//    func setProps(to props: Encrypted<SecureProps>) async
    
//    func save(on store: CypherMessengerStore) async throws
}

// TODO: Re-enable cache, and reuse the cache globally
public struct DecryptedModel<M: Model> {
    public let encrypted: M
    public var id: UUID { encrypted.id }
    public private(set) var props: M.SecureProps
    private let encryptionKey: SymmetricKey
    
    public func withProps<T>(get: (M.SecureProps) async throws -> T) async throws -> T {
        let props = try encrypted.props.decrypt(using: encryptionKey)
        return try await get(props)
    }
    
    public func modifyProps<T>(run: (inout M.SecureProps) async throws -> T) async throws -> T {
        var props = try encrypted.props.decrypt(using: encryptionKey)
        let value = try await run(&props)
        try await encrypted.props.update(to: props, using: encryptionKey)
        return value
    }
    
    public func setProp<T>(at keyPath: WritableKeyPath<M.SecureProps, T>, to value: T) async throws {
        try await modifyProps { props in
            props[keyPath: keyPath] = value
        }
    }
    
    init(model: M, encryptionKey: SymmetricKey) async throws {
        self.encrypted = model
        self.encryptionKey = encryptionKey
        self.props = try model.props.decrypt(using: encryptionKey)
    }
}

extension Model {
    func decrypted(using symmetricKey: SymmetricKey) async throws -> DecryptedModel<Self> {
        try await DecryptedModel(model: self, encryptionKey: symmetricKey)
    }
}
