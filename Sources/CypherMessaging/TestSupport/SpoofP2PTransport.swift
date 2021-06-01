import NIO

enum SpoofP2PTransportError: Error {
    case disconnected
}

public final class SpoofP2PTransportClient: P2PTransportClient {
    public weak var delegate: P2PTransportClientDelegate?
    public fileprivate(set) var connected: ConnectionState = .connecting
    public let state: P2PFrameworkState
    fileprivate weak var otherClient: SpoofP2PTransportClient?
    public let eventLoop: EventLoop
    
    internal init(
        state: P2PFrameworkState,
        eventLoop: EventLoop,
        otherClient: SpoofP2PTransportClient?
    ) {
        self.state = state
        self.otherClient = otherClient
        self.eventLoop = eventLoop
    }
    
    public func reconnect() -> EventLoopFuture<Void> {
        if otherClient == nil {
            self.connected = .disconnected
            return eventLoop.makeFailedFuture(SpoofP2PTransportError.disconnected)
        } else {
            self.connected = .connected
            return eventLoop.makeSucceededVoidFuture()
        }
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        self.connected = .disconnecting
        
        if let otherClient = otherClient {
            return otherClient.disconnect().map {
                self.connected = .disconnected
            }
        } else {
            self.connected = .disconnected
            return eventLoop.makeSucceededVoidFuture()
        }
    }
    
    public func sendMessage(_ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        guard connected == .connected, let otherClient = otherClient else {
            return eventLoop.makeFailedFuture(SpoofP2PTransportError.disconnected)
        }
        
        if let delegate = otherClient.delegate {
            return delegate.p2pConnection(otherClient, receivedMessage: buffer)
        } else {
            return eventLoop.makeSucceededVoidFuture()
        }
    }
    
    deinit {
        self.otherClient?.otherClient = nil
        self.otherClient = nil
    }
}

fileprivate final class SpoofTransportFactoryMedium {
    var clients = [String: SpoofP2PTransportClient]()
    
    private init() {}
    static let `default` = SpoofTransportFactoryMedium()
}

public final class SpoofP2PTransportFactory: P2PTransportClientFactory {
    public init() {}
    
    public let transportLayerIdentifier = "_spoof"
    
    public func createConnection(handle: P2PTransportFactoryHandle) -> EventLoopFuture<P2PTransportClient?> {
        let localClient = SpoofP2PTransportClient(
            state: handle.state,
            eventLoop: handle.eventLoop,
            otherClient: nil
        )
        
        let id = UUID().uuidString
        SpoofTransportFactoryMedium.default.clients[id] = localClient
        
        return handle.sendMessage(
            id,
            metadata: [:]
        ).map {
            return localClient
        }
    }
    
    public func receiveMessage(_ text: String, metadata: Document, handle: P2PTransportFactoryHandle) -> EventLoopFuture<P2PTransportClient?> {
        guard let client = SpoofTransportFactoryMedium.default.clients[text] else {
            return handle.eventLoop.makeSucceededFuture(nil)
        }
        
        let localClient = SpoofP2PTransportClient(
            state: handle.state,
            eventLoop: handle.eventLoop,
            otherClient: client
        )
        client.otherClient = localClient
        client.connected = .connected
        
        return handle.eventLoop.makeSucceededFuture(localClient)
    }
}
