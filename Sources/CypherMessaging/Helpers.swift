import NIO
import _NIOConcurrency

@available(macOS 10.15, iOS 13, *)
extension EventLoop {
    public func executeAsync<T>(_ block: @escaping @Sendable () async throws -> T) -> EventLoopFuture<T> {
        let promise = self.makePromise(of: T.self)
        execute {
            promise.completeWithTask(block)
        }
        return promise.futureResult
    }
}

public extension Array {
    func asyncMap<T>(_ run: (Element) async throws -> T) async rethrows -> [T] {
        var array = [T]()
        array.reserveCapacity(self.count)
        
        for element in self {
            let value = try await run(element)
            array.append(value)
        }
        
        return array
    }
    
    func asyncCompactMap<T>(_ run: (Element) async throws -> T?) async rethrows -> [T] {
        var array = [T]()
        array.reserveCapacity(self.count)
        
        for element in self {
            if let value = try await run(element) {
                array.append(value)
            }
        }
        
        return array
    }
    
    func asyncContains(where matches: (Element) async -> Bool) async -> Bool {
        for i in 0..<self.count {
            let element = self[i]
            if await matches(element) {
                return true
            }
        }
        
        return false
    }
    
    func asyncFirst(where matches: (Element) async -> Bool) async -> Element? {
        for i in 0..<self.count {
            let element = self[i]
            if await matches(element) {
                return element
            }
        }
        
        return nil
    }
}
