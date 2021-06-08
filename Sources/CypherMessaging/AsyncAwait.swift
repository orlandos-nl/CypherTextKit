import _NIOConcurrency

prefix operator <~

@available(macOS 12, iOS 15, *)
public prefix func <~<T>(value: EventLoopFuture<T>) async throws -> T {
    try await value.get()
}
