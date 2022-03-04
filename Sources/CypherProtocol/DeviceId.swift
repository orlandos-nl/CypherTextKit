import Foundation

/// A helper wrapper around `String`, so that the type cannot be used interchangably with other String based types
public struct DeviceId: CustomStringConvertible, Identifiable, Codable, Hashable, Equatable, Comparable, Sendable {
    public let raw: String
    
    public static func ==(lhs: DeviceId, rhs: DeviceId) -> Bool {
        lhs.raw == rhs.raw
    }
    
    public static func <(lhs: DeviceId, rhs: DeviceId) -> Bool {
        lhs.raw < rhs.raw
    }
    
    public init(from decoder: Decoder) throws {
        try self.init(String(from: decoder))
    }
    
    /// Generate a new DeviceId
    public init() {
        self.init(UUID().uuidString)
    }
    
    public init(_ description: String) {
        self.raw = description.lowercased()
    }
    
    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
    
    public var description: String { raw }
    public var id: String { raw }
}
