import BSON
import CypherProtocol
import Foundation

/// A string wrapper so that Strings are handled in a case-insensitive manner and to prevent mistakes like provding the wring String in a function
public struct GroupChatId: CustomStringConvertible, Identifiable, Codable, Hashable, Equatable, Comparable, ExpressibleByStringLiteral, Sendable {
    public let raw: String
    
    public static func ==(lhs: GroupChatId, rhs: GroupChatId) -> Bool {
        lhs.raw == rhs.raw
    }
    
    public static func <(lhs: GroupChatId, rhs: GroupChatId) -> Bool {
        lhs.raw < rhs.raw
    }
    
    public init() {
        self.raw = UUID().uuidString
    }
    
    public init(from decoder: Decoder) throws {
        try self.init(String(from: decoder))
    }
    
    public init(stringLiteral value: String) {
        self.init(value)
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

public struct ReferencedBlob<T: Codable & Sendable>: Codable, Sendable {
    public let id: String
    public var blob: T
    
    public init(id: String, blob: T) {
        self.id = id
        self.blob = blob
    }
}

public struct GroupChatConfig: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case members = "a"
        case createdAt = "b"
        case moderators = "c"
        case metadata = "d"
        case admin = "e"
        case kickedMembers = "f"
    }
    
    public private(set) var members: Set<Username>
    public let createdAt: Date
    public private(set) var moderators: Set<Username>
    public var metadata: Document
    public let admin: Username
    public private(set) var kickedMembers: Set<Username>
    
    public init(
        admin: Username,
        members: Set<Username>,
        moderators: Set<Username>,
        metadata: Document
    ) {
        assert(members.contains(admin), "Admin must be a member of the group")
        assert(moderators.isSubset(of: members), "All admins must be a member of the group")
        
        self.admin = admin
        self.members = members
        self.moderators = moderators
        self.createdAt = Date()
        self.metadata = metadata
        self.kickedMembers = []
    }
    
    public mutating func addMember(_ username: Username) {
        members.insert(username)
        kickedMembers.remove(username)
    }
    
    public mutating func removeMember(_ username: Username) {
        if let member = members.remove(username) {
            kickedMembers.insert(member)
        }
        moderators.remove(username)
    }
    
    public mutating func promoteAdmin(_ username: Username) {
        assert(members.contains(username))
        
        moderators.insert(username)
    }
    
    public mutating func demoteAdmin(_ username: Username) {
        moderators.remove(username)
    }
}
