import NIO

@available(macOS 12, iOS 15, *)
extension EventLoop {
    public func executeAsync<T>(_ block: @escaping () async throws -> T) -> EventLoopFuture<T> {
        let promise = self.makePromise(of: T.self)
        promise.completeWithAsync(block)
        return promise.futureResult
    }
}
