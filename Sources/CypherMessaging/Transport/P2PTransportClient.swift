import BSON
import NIO

public enum ConnectionState {
    case connecting, connected, disconnecting, disconnected
}

public struct Peer: Codable {
    public let username: Username
    public let deviceConfig: UserDeviceConfig
    public var deviceId: DeviceId { deviceConfig.deviceId }
    public var identity: PublicSigningKey { deviceConfig.identity }
    public var publicKey: PublicKey { deviceConfig.publicKey }
}

public struct P2PAdvertisement: Codable {
    internal struct Advertisement: Codable {
        let origin: Peer
    }
    
    internal let advertisement: Signed<Advertisement>
}

internal actor P2PMeshState {
    
}

/// Can only be initialised by the CypherTextKit
/// Contains internal and public information about the connection and conncted clients
public struct P2PFrameworkState {
    public let remote: Peer
    internal var username: Username { remote.username }
    internal var deviceId: DeviceId { remote.deviceId }
    internal var identity: PublicSigningKey { remote.identity }
    internal let isMeshEnabled: Bool
    
    // TODO: Attempt Offline Verification
    internal var verified = true
    internal let mesh = P2PMeshState()
}

/// PeerToPeerTransportClient is used to create a direct connection between two devices.
/// The client implementation defined below does not need to verify the identity of the other party.
/// These transport clients need not concern themselves with end-to-end encryption, as the data they receive is already encrypted.
///
/// CypherTextKit may opt to use a direct connection as a _replacement_ for via-server communication, as to improve security, bandwidth AND latency.
@available(macOS 10.15, iOS 13, *)
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
    
    /// Disconnects any active connections.
    func disconnect() async
    
    /// Sends a buffer to the remote. The remote, upon receiving, must call `delegate.receiveMessage`
    func sendMessage(_ buffer: ByteBuffer) async throws
}

public enum P2PTransportClosureOption {}

@available(macOS 10.15, iOS 13, *)
public protocol P2PTransportClientDelegate: AnyObject {
    func p2pConnection(_ connection: P2PTransportClient, receivedMessage buffer: ByteBuffer) async throws
    func p2pConnectionClosed(_ connection: P2PTransportClient) async throws
}

@available(macOS 10.15, iOS 13, *)
public protocol P2PTransportFactoryDelegate: AnyObject {
    func p2pTransportDiscovered(
        _ connection: P2PTransportClient,
        remotePeer: Peer
    ) async throws
    
    func createLocalDeviceAdvertisement() async throws -> P2PAdvertisement
}

public struct P2PTransportCreationRequest {
    public let state: P2PFrameworkState
}

@available(macOS 10.15, iOS 13, *)
public typealias PeerToPeerConnectionBuilder = (P2PTransportCreationRequest) -> P2PTransportClient

/// P2PTransportClientFactory is a _stateful_ factory that can instantiate new connections
///
/// It can make use of its own networking layers, or the existing connection through the server, to instantiate a session.
///
/// Example: Apple devices can use Multipeer Connectivity, possibly without making use of server-side communication.
///
/// Example: WebRTC based implementations are likely to make use of the handle to send and receive SDPs. The factory can then make use of internal state for storing incomplete connections.
@available(macOS 10.15, iOS 13, *)
public protocol P2PTransportClientFactory: AnyObject {
    var transportLayerIdentifier: String { get }
    
    /// Whether this transport type supports relaying messages for between two peers
    var isMeshEnabled: Bool { get }
    
    /// The delegate receives signals of factory-discovered peers. MUST be `weak` to prevent memory leaks.
    ///
    /// CypherTextKit is responsible for managing and delegating data received from this channel
    var delegate: P2PTransportFactoryDelegate? { get set }
    
    func receiveMessage(
        _ text: String,
        metadata: Document,
        handle: P2PTransportFactoryHandle
    ) async throws -> P2PTransportClient?
    
    /// Creates a new P2PConnection with a remote client. Any necessary communication _must_ go through `handle`.
    ///
    /// If a connection can only be instantiated after a response, this function _may_ return `nil` instead.
    /// In which case the `receiveMessage` callback is used to finalise a connection.
    ///
    /// `createConnection` _should_ complete after any current actions. It _may_ also delay the completion until a network related task completed, such as discovery on the local network or nearby BlueTooth devices. In which case the function _must_ implement a reasonable termination deadline.
    func createConnection(
        handle: P2PTransportFactoryHandle
    ) async throws -> P2PTransportClient?
}

extension P2PTransportClientFactory {
    public var isMeshEnabled: Bool { false }
    
    public func createLocalTransportState(
        advertisement: P2PAdvertisement
    ) async throws -> P2PFrameworkState {
        let remote = try advertisement.advertisement.readWithoutVerifying()
        guard advertisement.advertisement.isSigned(by: remote.origin.identity) else {
            throw CypherSDKError.invalidSignature
        }
        
        return P2PFrameworkState(
            remote: remote.origin,
            isMeshEnabled: isMeshEnabled,
            verified: false
        )
    }
}

/// An interface through which can be communicated with the remote device
@available(macOS 10.15, iOS 13, *)
public struct P2PTransportFactoryHandle {
    internal let transportLayerIdentifier: String
    internal let messenger: CypherMessenger
    internal let targetConversation: TargetConversation
    public let state: P2PFrameworkState
    
    public func sendMessage(
        _ text: String,
        metadata: Document = [:]
    ) async throws {
        try await messenger._queueTask(
            .sendMessage(
                SendMessageTask(
                    message: CypherMessage(
                        message: SingleCypherMessage(
                            messageType: .magic,
                            messageSubtype: "_/p2p/0/\(transportLayerIdentifier)",
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
                    pushType: .none,
                    messageId: UUID().uuidString
                )
            )
        )
    }
}
