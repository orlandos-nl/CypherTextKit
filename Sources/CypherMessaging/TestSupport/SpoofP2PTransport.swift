import NIO

enum SpoofP2PTransportError: Error {
    case disconnected
}

@available(macOS 10.15, iOS 13, *)
public final class SpoofP2PTransportClient: P2PTransportClient {
    public weak var delegate: P2PTransportClientDelegate?
    public fileprivate(set) var connected: ConnectionState = .connecting
    public let state: P2PFrameworkState
    fileprivate weak var otherClient: SpoofP2PTransportClient?
    
    internal init(
        state: P2PFrameworkState,
        otherClient: SpoofP2PTransportClient?
    ) {
        self.state = state
        self.otherClient = otherClient
    }
    
    public func reconnect() async throws {
        if otherClient == nil {
            self.connected = .disconnected
            throw SpoofP2PTransportError.disconnected
        } else {
            self.connected = .connected
        }
    }
    
    public func disconnect() async {
        if connected == .disconnected || connected == .disconnecting {
            return
        }
        
        self.connected = .disconnecting
        
        if let otherClient = otherClient {
            await otherClient.disconnect()
            self.connected = .disconnected
        } else {
            self.connected = .disconnected
        }
    }
    
    public func sendMessage(_ buffer: ByteBuffer) async throws {
        guard connected == .connected, let otherClient = otherClient else {
            throw SpoofP2PTransportError.disconnected
        }
        
        if let delegate = otherClient.delegate {
            try await delegate.p2pConnection(otherClient, receivedMessage: buffer)
        }
    }
    
    deinit {
        self.otherClient?.otherClient = nil
        self.otherClient = nil
    }
}

@available(macOS 10.15, iOS 13, *)
fileprivate final class SpoofTransportFactoryMedium {
    @CypherTextKitActor var clients = [String: SpoofP2PTransportClient]()
    @CypherTextKitActor var devices = [String: SpoofP2PTransportFactory]()
    
    private init() {}
    static let `default` = SpoofTransportFactoryMedium()
}

@available(macOS 10.15, iOS 13, *)
public final class SpoofP2PTransportFactory: P2PTransportClientFactory {
    @CypherTextKitActor public static func clearMesh() {
        SpoofTransportFactoryMedium.default.devices = [:]
    }
    
    @discardableResult
    @CypherTextKitActor public static func connectMesh(from: String, to: String) async throws -> Bool {
        guard
            let from = SpoofTransportFactoryMedium.default.devices[from],
            let to = SpoofTransportFactoryMedium.default.devices[to],
            let fromAdvertisement = try await from.delegate?.createLocalDeviceAdvertisement(),
            let toAdvertisement = try await to.delegate?.createLocalDeviceAdvertisement()
        else {
            return false
        }
        
        let fromState = try await from.createLocalTransportState(advertisement: toAdvertisement)
        let fromClient = SpoofP2PTransportClient(
            state: fromState,
            otherClient: nil
        )
        
        let toState = try await to.createLocalTransportState(advertisement: fromAdvertisement)
        let toClient = SpoofP2PTransportClient(
            state: toState,
            otherClient: fromClient
        )
        
        fromClient.otherClient = toClient
        
        try await from.delegate?.p2pTransportDiscovered(
            fromClient,
            remotePeer: fromState.remote
        )
        try await to.delegate?.p2pTransportDiscovered(
            toClient,
            remotePeer: toState.remote
        )
        
        fromClient.connected = .connected
        toClient.connected = .connected
        return true
    }
    
    public let transportLayerIdentifier = "_spoof"
    public let isMeshEnabled: Bool
    public weak var delegate: P2PTransportFactoryDelegate?
    
    public init() {
        self.isMeshEnabled = false
    }
    
    @CypherTextKitActor public init(meshId: String) {
        self.isMeshEnabled = true
        
        SpoofTransportFactoryMedium.default.devices[meshId] = self
    }
    
    @CypherTextKitActor public func createConnection(handle: P2PTransportFactoryHandle) async throws -> P2PTransportClient? {
        let localClient = SpoofP2PTransportClient(
            state: handle.state,
            otherClient: nil
        )
        
        let id = UUID().uuidString
        SpoofTransportFactoryMedium.default.clients[id] = localClient
        
        try await handle.sendMessage(
            id,
            metadata: [:]
        )
        
        return localClient
    }
    
    @CypherTextKitActor public func receiveMessage(_ text: String, metadata: Document, handle: P2PTransportFactoryHandle) async throws -> P2PTransportClient? {
        guard let client = SpoofTransportFactoryMedium.default.clients[text] else {
            return nil
        }
        
        let localClient = SpoofP2PTransportClient(
            state: handle.state,
            otherClient: client
        )
        client.otherClient = localClient
        client.connected = .connected
        
        return localClient
    }
}
