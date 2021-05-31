import BSON
import NIO

public enum ConnectionState {
    case connecting, connected, disconnecting, disconnected
}

/// Can only be initialised by the CypherTextKit
/// Contains internal and public information about the connection and conncted clients
public struct P2PFrameworkState {
    internal let username: Username
    internal let deviceId: DeviceId
    internal let identity: PublicSigningKey
}

/// PeerToPeerTransportClient is used to create a direct connection between two devices.
/// The client implementation defined below does not need to verify the identity of the other party.
///
/// CypherTextKit may opt to use a direct connection as a _replacement_ for via-server communication, as to improve security, bandwidth AND latency.
public protocol P2PTransportClient: AnyObject {
    /// The delegate receives incoming data from the the remote peer. MUST be `weak` to prevent memory leaks.
    ///
    /// CypherTextKit is responsible for managing and delegating data received from this channel
    var delegate: P2PTransportClientDelegate? { get set }
    
    var connected: ConnectionState { get }
    
    /// Can only be initialised by the CypherTextKit
    /// Contains internal and public information about the connection and conncted clients
    ///
    /// Obtained on creation through `P2PTransportClientFactory`
    var state: P2PFrameworkState { get }
    
    /// (Re-)starts the connection(s).
    func reconnect() -> EventLoopFuture<Void>
    
    /// Disconnects any active connections.
    func disconnect() -> EventLoopFuture<Void>
    
    /// Sends a buffer to the remote. The remote, upon receiving, must call `delegate.receiveMessage`
    func sendMessage(_ buffer: ByteBuffer) -> EventLoopFuture<Void>
}

public enum P2PTransportClosureOption {
    case reconnnectPossible
}

public protocol P2PTransportClientDelegate: AnyObject {
    func p2pConnection(_ connection: P2PTransportClient, receivedMessage buffer: ByteBuffer) -> EventLoopFuture<Void>
    func p2pConnection(_ connection: P2PTransportClient, closedWithOptions: Set<P2PTransportClosureOption>) -> EventLoopFuture<Void>
}

public struct P2PTransportCreationRequest {
    public let state: P2PFrameworkState
}

public typealias PeerToPeerConnectionBuilder = (P2PTransportCreationRequest) -> P2PTransportClient

/// P2PTransportClientFactory is a _stateful_ factory that can instantiate new connections
///
/// It can make use of its own networking layers, or the existing connection through the server, to instantiate a session.
///
/// Example: Apple devices can use Multipeer Connectivity, possibly without making use of server-side communication.
///
/// Example: WebRTC based implementations are likely to make use of the handle to send and receive SDPs. The factory can then make use of internal state for storing incomplete connections.
public protocol P2PTransportClientFactory {
    var transportLayerIdentifier: String { get }
    
    func receiveMessage(
        _ text: String,
        metadata: Document,
        handle: P2PTransportFactoryHandle
    ) -> EventLoopFuture<P2PTransportClient?>
    
    /// Creates a new P2PConnection with a remote client. Any necessary communication _must_ go through `handle`.
    ///
    /// If a connection can only be instantiated after a response, this function _may_ return `nil` instead.
    /// In which case the `receiveMessage` callback is used to finalise a connection.
    ///
    /// `createConnection` _should_ complete after any current actions. It _may_ also delay the completion until a network related task completed, such as discovery on the local network or nearby BlueTooth devices. In which case the function _must_ implement a reasonable termination deadline.
    func createConnection(
        handle: P2PTransportFactoryHandle
    ) -> EventLoopFuture<P2PTransportClient?>
}

/// An interface through which can be communicated with the remote device
public struct P2PTransportFactoryHandle {
    internal let transportLayerIdentifier: String
    internal let messenger: CypherMessenger
    internal let targetConversation: TargetConversation
    public let state: P2PFrameworkState
    public var eventLoop: EventLoop { messenger.eventLoop }
    
    public func sendMessage(
        _ text: String,
        metadata: Document = [:]
    ) -> EventLoopFuture<Void> {
        messenger._queueTask(
            .sendMessage(
                SendMessageTask(
                    message: CypherMessage(
                        message: SingleCypherMessage(
                            messageType: .magic,
                            messageSubtype: "_/p2p/\(transportLayerIdentifier)",
                            text: text,
                            metadata: metadata,
                            destructionTimer: nil,
                            sentDate: Date(),
                            preferredPushType: nil,
                            order: 0,
                            target: targetConversation
                        )
                    ),
                    recipient: state.username,
                    recipientDeviceId: state.deviceId,
                    localId: nil,
                    messageId: UUID().uuidString
                )
            )
        )
    }
}
