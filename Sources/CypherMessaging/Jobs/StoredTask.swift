import NIO
import BSON
import Foundation

@available(macOS 10.15, iOS 13, *)
public protocol StoredTask: Codable {
    var key: TaskKey { get }
    var isBackgroundTask: Bool { get }
    var retryMode: TaskRetryMode { get }
    var priority: TaskPriority { get }
    var requiresConnectivity: Bool { get }
    
    func execute(on messenger: CypherMessenger) async throws
    func onDelayed(on messenger: CypherMessenger) async throws
}

@available(macOS 10.15, iOS 13, *)
typealias TaskDecoder = (Document) throws -> StoredTask

public struct TaskPriority {
    enum _Raw: Comparable {
        case lowest, lower, normal, higher, urgent
    }
    
    let raw: _Raw
    
    /// Take your time, it's expected to take a while
    public static let lowest = TaskPriority(raw: .lowest)
    
    /// Not as urgent as regular user actions, but please do not take all the time in the world
    public static let lower = TaskPriority(raw: .lower)
    
    /// Regular user actions
    public static let normal = TaskPriority(raw: .normal)
    
    /// This is needed fast, think of real-time communication
    public static let higher = TaskPriority(raw: .higher)
    
    /// THIS CANNOT WAIT
    public static let urgent = TaskPriority(raw: .urgent)
}

public struct TaskRetryMode {
    enum _Raw {
        case never
        case always
        case retryAfter(TimeInterval, maxAttempts: Int?)
    }
    
    let raw: _Raw
    
    public static let never = TaskRetryMode(raw: .never)
    public static let always = TaskRetryMode(raw: .always)
    public static func retryAfter(_ interval: TimeInterval, maxAttempts: Int?) -> TaskRetryMode {
        .init(raw: .retryAfter(interval, maxAttempts: maxAttempts))
    }
}

public struct TaskKey: ExpressibleByStringLiteral, RawRepresentable, Hashable {
    private let taskName: String
    
    public var rawValue: String { taskName }
    
    public init(rawValue: String) {
        self.taskName = rawValue
    }
    
    public init(stringLiteral value: StringLiteralType) {
        self.taskName = value
    }
}
