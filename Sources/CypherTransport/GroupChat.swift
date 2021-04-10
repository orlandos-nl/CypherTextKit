import BSON
import CypherProtocol
import Foundation

/// A string wrapper so that Strings are handled in a case-insensitive manner and to prevent mistakes like provding the wring String in a function
public struct GroupChatId: CustomStringConvertible, Identifiable, Codable, Hashable, Equatable, Comparable, ExpressibleByStringLiteral {
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

public struct GroupChatConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case groupChatId = "a"
        case members = "b"
        case createdAt = "c"
        case admins = "d"
        case metadata = "e"
    }
    
    public let groupChatId: GroupChatId
    public private(set) var members: Set<Username>
    public let createdAt: Date
    public private(set) var admins: Set<Username>
    public var metadata: Document
    
    public init(members: Set<Username>, admins: Set<Username>) {
        assert(admins.isSubset(of: members), "All admins must be a member of the group")
        
        self.groupChatId = GroupChatId()
        self.members = members
        self.admins = admins
        self.createdAt = Date()
        self.metadata = Document()
    }
    
    public mutating func addMember(_ username: Username) {
        members.insert(username)
    }
    
    public mutating func removeMember(_ username: Username) {
        members.remove(username)
        admins.remove(username)
    }
    
    public mutating func promoteAdmin(_ username: Username) {
        assert(members.contains(username))
        
        admins.insert(username)
    }
    
    public mutating func demoteAdmin(_ username: Username) {
        admins.remove(username)
    }
}
