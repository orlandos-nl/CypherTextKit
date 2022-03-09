import Dribble
import NIO
//import NIOTransportServices

public enum IPv6TCPP2PError: Error {
    case reconnectFailed, timeout, socketCreationFailed
}

@available(macOS 10.15, iOS 13, *)
private final class BufferHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var client: IPv6TCPP2PTransportClient?
    
    init(client: IPv6TCPP2PTransportClient) {
        self.client = client
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        guard let client = client else {
            context.close(promise: nil)
            return
        }
        
        if let delegate = client.delegate {
            context.eventLoop.executeAsync {
                _ = try await delegate.p2pConnection(client, receivedMessage: buffer)
            }.whenFailure { error in
                context.fireErrorCaught(error)
            }
        }
    }
}

@available(macOS 10.15, iOS 13, *)
final class IPv6TCPP2PTransportClient: P2PTransportClient {
    public weak var delegate: P2PTransportClientDelegate?
    public private(set) var connected = ConnectionState.connected
    private let channel: Channel
    public var state: P2PFrameworkState
    
    init(state: P2PFrameworkState, channel: Channel) {
        self.state = state
        self.channel = channel
    }
    
    public func disconnect() async {
        do {
            try await channel.close()
        } catch {}
    }
    
    public func sendMessage(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(buffer)
    }
    
    static func initialize(state: P2PFrameworkState, channel: Channel) -> EventLoopFuture<IPv6TCPP2PTransportClient> {
        let client = IPv6TCPP2PTransportClient(state: state, channel: channel)
        return channel.pipeline.addHandler(BufferHandler(client: client)).map {
            client
        }
    }
}

public struct StunCredentials {
    enum _Credentials {
        case none
        case password(String)
        case tuple(username: String, realm: String, password: String)
    }
    
    let _credentials: _Credentials
    
    public init() {
        _credentials = .none
    }
    
    public init(password: String) {
        _credentials = .password(password)
    }
    
    public init(username: String, realm: String, password: String) {
        _credentials = .tuple(username: username, realm: realm, password: password)
    }
}

public struct StunConfig {
    let server: SocketAddress
    let credentials: StunCredentials?
    
    public init(
        server: SocketAddress,
        credentials: StunCredentials = StunCredentials()
    ) {
        self.server = server
        self.credentials = credentials
    }
}

@available(macOS 10.15, iOS 13, *)
public final class IPv6TCPP2PTransportClientFactory: P2PTransportClientFactory {
    public let transportLayerIdentifier = "_ipv6-tcp"
    public let isMeshEnabled = false
    public weak var delegate: P2PTransportFactoryDelegate?
    let eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    let stun: StunConfig?
    
    public init(stun: StunConfig? = nil) {
        self.stun = stun
    }
    
    public func receiveMessage(_ text: String, metadata: Document, handle: P2PTransportFactoryHandle) async throws -> P2PTransportClient? {
        guard
            let host = metadata["ip"] as? String,
            let port = metadata["port"] as? Int
        else {
            throw IPv6TCPP2PError.socketCreationFailed
        }
        
        return try await ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(30))
            .connect(host: host, port: port)
            .flatMap { channel in
                IPv6TCPP2PTransportClient.initialize(state: handle.state, channel: channel)
            }.get()
    }
    
    private func findAddress() async throws -> SocketAddress {
        if let stun = stun {
            do {
                let stunClient = try await StunClient.connect(to: stun.server)
                return try await stunClient.requestBinding(addressFamily: .ipv6)
            } catch {
                // STUN failed, try a different route
            }
        }
        
        // TODO: Support TURN?
        
        // No STUN or TURN, find sensible local interface as a last effort
        findInterface: do {
            let interfaces = try System.enumerateDevices()
            
            for interface in interfaces {
                if
//                    interface.name == "en0",
                    let address = interface.address,
                    address.protocol == .inet6,
//                    !address.isMulticast,
                    let foundIpAddress = address.ipAddress,
                    !foundIpAddress.hasPrefix("fe80:"),
                    !foundIpAddress.contains("::1")
                {
                    return try SocketAddress(ipAddress: foundIpAddress, port: 0)
                }
            }
            
            throw IPv6TCPP2PError.socketCreationFailed
        } catch {
            debugLog("Failed to create P2PIPv6 Session", error)
            throw error
        }
    }
    
    public func createConnection(handle: P2PTransportFactoryHandle) async throws -> P2PTransportClient? {
        let address = try await findAddress()
        let promise = handle.messenger.eventLoop.makePromise(of: Optional<P2PTransportClient>.self)
        
//        #if canImport(Network) && false
//        #else
        ServerBootstrap(group: eventLoop)
            .childChannelInitializer { channel in
                return IPv6TCPP2PTransportClient.initialize(
                    state: handle.state,
                    channel: channel
                ).map { client in
                    promise.succeed(client)
                }.flatMapErrorThrowing { error in
                    promise.fail(error)
                    throw error
                }
            }
            .bind(to: address)
            .flatMap { channel -> EventLoopFuture<Void> in
                self.eventLoop.next().scheduleTask(in: .seconds(30)) { () in
                    promise.fail(IPv6TCPP2PError.timeout)
                    channel.close(promise: nil)
                }
                
                guard
                    let localAddress = channel.localAddress,
                    let port = localAddress.port
                else {
                    promise.fail(IPv6TCPP2PError.socketCreationFailed)
                    return self.eventLoop.makeFailedFuture(IPv6TCPP2PError.socketCreationFailed)
                }
                
                return channel.eventLoop.executeAsync {
                    try await handle.sendMessage("", metadata: [
                        "ip": address.ipAddress,
                        "port": port
                    ])
                }
            }.whenFailure { error in
                debugLog("Failed to host IPv6 Server", error)
                promise.fail(error)
            }
        
        return try await promise.futureResult.get()
//        #endif
    }
}
