import NIO
import NIOTransportServices

enum IPv6TCPP2PError: Error {
    case reconnectFailed, timeout, socketCreationFailed
}

@available(macOS 12, iOS 15, *)
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
            _ = delegate.p2pConnection(client, receivedMessage: buffer)
        }
    }
}

@available(macOS 12, iOS 15, *)
final class IPv6TCPP2PTransportClient: P2PTransportClient {
    public weak var delegate: P2PTransportClientDelegate?
    public private(set) var connected = ConnectionState.connected
    private let channel: Channel
    public var state: P2PFrameworkState
    
    init(state: P2PFrameworkState, channel: Channel) {
        self.state = state
        self.channel = channel
    }
    
    public func reconnect() -> EventLoopFuture<Void> {
        channel.eventLoop.makeFailedFuture(IPv6TCPP2PError.reconnectFailed)
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        channel.close()
    }
    
    public func sendMessage(_ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        channel.writeAndFlush(buffer)
    }
    
    static func initialize(state: P2PFrameworkState, channel: Channel) -> EventLoopFuture<IPv6TCPP2PTransportClient> {
        let client = IPv6TCPP2PTransportClient(state: state, channel: channel)
        return channel.pipeline.addHandler(BufferHandler(client: client)).map {
            client
        }
    }
}

@available(macOS 12, iOS 15, *)
public final class IPv6TCPP2PTransportClientFactory: P2PTransportClientFactory {
    public let transportLayerIdentifier = "_ipv6-tcp"
    let eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    
    public init() {}
    
    public func receiveMessage(_ text: String, metadata: Document, handle: P2PTransportFactoryHandle) -> EventLoopFuture<P2PTransportClient?> {
        guard
            let host = metadata["ip"] as? String,
            let port = metadata["port"] as? Int
        else {
            return eventLoop.makeFailedFuture(IPv6TCPP2PError.socketCreationFailed)
        }
        
        return ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(30))
            .connect(host: host, port: port)
            .flatMap { channel in
                IPv6TCPP2PTransportClient.initialize(state: handle.state, channel: channel)
            }.map { $0 }
    }
    
    public func createConnection(handle: P2PTransportFactoryHandle) -> EventLoopFuture<P2PTransportClient?> {
        let ipAddress: String
        
        findInterface: do {
            let interfaces = try System.enumerateDevices()
            
            for interface in interfaces {
                if
                    interface.name == "en0",
                    let address = interface.address,
                    address.protocol == .inet6,
                    !address.isMulticast,
                    let foundIpAddress = address.ipAddress,
                    !foundIpAddress.hasPrefix("fe80:")
                {
                    ipAddress = foundIpAddress
                    break findInterface
                }
            }
            
            throw IPv6TCPP2PError.socketCreationFailed
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        
        let promise = handle.eventLoop.makePromise(of: Optional<P2PTransportClient>.self)
        
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
            .bind(host: ipAddress, port: 0)
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
                
                return handle.sendMessage("", metadata: [
                    "ip": ipAddress,
                    "port": port
                ])
            }.cascadeFailure(to: promise)
        
        return promise.futureResult
//        #endif
    }
}
