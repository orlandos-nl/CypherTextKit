import BSON
import Foundation
import Crypto

/// Used when encrypting a specific value
public final class Encrypted<T: Codable>: Codable, @unchecked Sendable {
    private var value: AES.GCM.SealedBox
    @CryptoActor private var wrapped: T?
    
    public init(_ value: T, encryptionKey: SymmetricKey) throws {
        // Wrap the type so it can be encoded by BSON
        let wrapper = PrimitiveWrapper(value: value)
        // Encode the value through its wrapper
        let data = try BSONEncoder().encode(wrapper).makeData()
        
        // Encrypt & store the encoded data
        self.value = try AES.GCM.seal(data, using: encryptionKey)
    }
    
    @CryptoActor
    public func update(to value: T, using encryptionKey: SymmetricKey) throws {
        self.wrapped = value
        let wrapper = PrimitiveWrapper(value: value)
        let data = try BSONEncoder().encode(wrapper).makeData()
        self.value = try AES.GCM.seal(data, using: encryptionKey)
    }
    
    // The inverse of the initializer
    @CryptoActor
    public func decrypt(using encryptionKey: SymmetricKey) throws -> T {
        if let wrapped = wrapped {
            return wrapped
        }
        
        // Decrypt the data into encoded data
        let data = try AES.GCM.open(value, using: encryptionKey)
        
        // Decode the data
        let wrapper = try BSONDecoder().decode(PrimitiveWrapper<T>.self, from: Document(data: data))
        
        // Return the value
        let value = wrapper.value
        wrapped = value
        return value
    }
    
    @CryptoActor
    public func makeData() -> Data {
        value.combined!
    }
    
    public init(representing box: AES.GCM.SealedBox) {
        self.value = box
    }
    
    public func encode(to encoder: Encoder) throws {
        try value.combined?.encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        self.value = try AES.GCM.SealedBox(combined: Data(from: decoder))
    }
}

private struct PrimitiveWrapper<T: Codable>: Codable {
    private enum CodingKeys: String, CodingKey {
        case value = "a"
    }
    
    let value: T
}
