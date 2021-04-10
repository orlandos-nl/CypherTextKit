import Foundation
import Crypto

public protocol Model: AnyObject, Codable {
    associatedtype SecureProps: Codable
    
    var id: UUID { get }
    var props: Encrypted<SecureProps> { get set }
}

@dynamicMemberLookup
public struct DecryptedModel<M: Model> {
    public var encrypted: M
    private let encryptionKey: SymmetricKey
    
    private final class DecryptedPropertyCache {
        var props: M.SecureProps?
    }
    
    public var id: UUID {
        encrypted.id
    }
    
    private var propertyCache = DecryptedPropertyCache()
    
    public var props: M.SecureProps {
        get {
//            if let cached = propertyCache.props {
//                return cached
//            } else {
                do {
                    let props = try encrypted.props.decrypt(using: encryptionKey)
                    propertyCache.props = props
                    return props
                } catch {
                    fatalError("Props cannot be decrypted for \(M.self)")
                }
//            }
        }
        nonmutating set {
            propertyCache.props = newValue
            
            do {
                encrypted.props = try Encrypted(newValue, encryptionKey: encryptionKey)
            } catch {
                fatalError("Props cannot be encrypted for \(M.self)")
            }
        }
    }
    
    init(model: M, encryptionKey: SymmetricKey) {
        self.encrypted = model
        self.encryptionKey = encryptionKey
    }
    
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<M.SecureProps, T>) -> T {
        get {
            props[keyPath: keyPath]
        }
        nonmutating set {
            props[keyPath: keyPath] = newValue
        }
    }
}

extension Model {
    func decrypted(using symmetricKey: SymmetricKey) -> DecryptedModel<Self> {
        DecryptedModel(model: self, encryptionKey: symmetricKey)
    }
}
