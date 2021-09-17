import Foundation
import CypherProtocol
import NIO

public enum AuthenticationMethod {
    case identity(PrivateSigningKey)
    case password(String)
}

public struct Credentials {
    public let username: Username
    public let deviceId: DeviceId
    public let method: AuthenticationMethod
    
    public init(username: Username, deviceId: DeviceId, method: AuthenticationMethod) {
        self.username = username
        self.deviceId = deviceId
        self.method = method
    }
}

public enum AuthenticationState {
    case unauthenticated, authenticated, authenticationFailure
}

/// A transport client is responsible for relaying information to and from third parties. It's commonly implemented in the form of an API client, but can also take the form of an XMPP client or even QR code reader/writer.
/// While CypherMessenger is agnostic to the transport method used, there are certain requirements as defined in this protocol.
///
/// These transport clients need not concern themselves with end-to-end encryption, as the data they receive is already encrypted.
public protocol CypherServerTransportClient: AnyObject {
    /// The delegate receives incoming events from the server. MUST be `weak` to prevent memory leaks.
    ///
    /// Any `CypherServerEvent` received must be emitted to this delegate.
    /// Upon successful handling of the event by the delegate, a TransportClient _SHOULD_ emit an acknowledgement to the server.
    /// The server _SHOULD_ wait for this acknowledgement, and then remove the message.
    /// The server _SHOULD_ retransmit the message if no acknowledgement was received.
    var delegate: CypherTransportClientDelegate? { get }
    
    func setDelegate(to delegate: CypherTransportClientDelegate) async throws
    
    /// `true` when logged in, `false` on incorrect login, `nil` when no server request has been executed yet
    var authenticated: AuthenticationState { get }
    
    /// When `true`, the CypherMessenger's internals may call the `sendMultiRecipientMessage` method.
    /// Supporting MultiRecipient Messages allows the app to expend less data uploading files to multiple recipients.
    var supportsMultiRecipientMessages: Bool { get }
    
    /// (Re-)starts the connection(s).
    func reconnect() async throws
    
    /// Disconnects any active connections.
    func disconnect() async throws
    
    /// Sends a read receipt to (all of) another user's devices
    /// Receips use a random identifier that's only known by the sender & recipient, so they can be publicly communicated
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    ///
    /// The backend and/or protocol must ensure that `delegate?.receiveServerEvent(.messageDisplayed(..))` is received on all of the other user's devices
    /// The provided message's ID is the `remoteId` as supplied in this call.
    ///
    /// The provided current user's `Username` and `DeviceId` _must_ be received through the intialisation phase of this transport client.
    func sendMessageReadReceipt(byRemoteId remoteId: String, to username: Username) async throws
    
    /// Sends a received receipt to (all of) another user's devices
    /// Receips use a random identifier that's only known by the sender & recipient, so they can be publicly communicated
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    ///
    /// The backend and/or protocol must ensure that `delegate?.receiveServerEvent(.messageReceived(..))` is received on all of the other user's devices
    /// The provided message's ID is the `remoteId` as supplied in this call.
    ///
    /// The provided current user's `Username` and `DeviceId` _must_ be received through the intialisation phase of this transport client.
    func sendMessageReceivedReceipt(byRemoteId remoteId: String, to username: Username) async throws
    
    /// When the current app is trying to add itself as a device to an existing user's device list, this method is called
    /// The implementation must attempt to call `delegate?.receiveServerEvent(.requestDeviceRegistery(config))` on the master device, likely through a common backend
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    func requestDeviceRegistery(_ config: UserDeviceConfig) async throws
    
    /// Reads the Config published or shared by another user. This config is commonly fetched from a shared backend. However, alternative routes of fetching key bundles is possible _and_ permitted.
    /// Other user's config files change when the device list changes.
    func readKeyBundle(forUsername username: Username) async throws -> UserConfig
    
    /// Published the user's key bundle so it can be fetched by other users. While this is commonly published to a backend, this could also be stored & exported as a form of "Contact Card" blob.
    /// Please note that with multi device support enabled, each change to the device list should be known to other users.
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    func publishKeyBundle(_ data: UserConfig) async throws
    
    /// Encodes andPublishes a Codable instance. This blob is used by the SDK to create public information.
    /// This feature is currently only used by the SDK for the creation of group chat configs. Published GroupChat configs are planned to be deprecated in a future release.
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    func publishBlob<C: Codable>(_ blob: C) async throws -> ReferencedBlob<C>
    
    /// Reads a published blob, and decodes it into a Codable instance. This blob is used by the SDK to create public information.
    /// This feature is currently only used by the SDK for the creation of group chat configs. Published GroupChat configs are planned to be deprecated in a future release.
    func readPublishedBlob<C: Codable>(byId id: String, as type: C.Type) async throws -> ReferencedBlob<C>?
    
    /// Sends a single message to another single device. This device may belong to the same user as the sender.
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    func sendMessage(_ message: RatchetedCypherMessage, toUser username: Username, otherUserDeviceId: DeviceId, pushType: PushType, messageId: String) async throws
    
    /// Sends a single blob, targeted at multiple users. The backend _may_ erase any `ContainerKey` not targeted at the recipeint, before sending it to the other client.
    /// MultiRecipeitnMessages are commonly used in multi-device or group chat scenarios, where a large blob is sent to many devices.
    /// If `supportsMultiRecipientMessages` is `false`, this method will not be called. `sendMesasge` will be called multiple times instead.
    ///
    /// This function must complete after having successfully sent a message to the server, this should include an acknowledgement from the server.
    func sendMultiRecipientMessage(_ message: MultiRecipientCypherMessage, pushType: PushType, messageId: String) async throws
}

public protocol ConnectableCypherTransportClient: CypherServerTransportClient {
    static func login(_ request: TransportCreationRequest) async throws -> Self
}

public protocol CypherTransportClientDelegate: AnyObject {
    func receiveServerEvent(_ event: CypherServerEvent) async throws
}

public struct CypherServerEvent {
    enum _CypherServerEvent {
        case multiRecipientMessageSent(MultiRecipientCypherMessage, id: String, byUser: Username, deviceId: DeviceId)
        case messageSent(RatchetedCypherMessage, id: String, byUser: Username, deviceId: DeviceId)
        case messageDisplayed(by: Username, deviceId: DeviceId, id: String)
        case messageReceived(by: Username, deviceId: DeviceId, id: String)
        case requestDeviceRegistery(UserDeviceConfig)
    }
    
    internal let raw: _CypherServerEvent
    
    public static func multiRecipientMessageSent(_ message: MultiRecipientCypherMessage, id: String, byUser user: Username, deviceId: DeviceId) -> CypherServerEvent {
        CypherServerEvent(raw: .multiRecipientMessageSent(message, id: id, byUser: user, deviceId: deviceId))
    }
    
    public static func messageSent(_ message: RatchetedCypherMessage, id: String, byUser user: Username, deviceId: DeviceId) -> CypherServerEvent {
        CypherServerEvent(raw: .messageSent(message, id: id, byUser: user, deviceId: deviceId))
    }
    
    public static func messageDisplayed(by user: Username, deviceId: DeviceId, id: String) -> CypherServerEvent {
        CypherServerEvent(raw: .messageDisplayed(by: user, deviceId: deviceId, id: id))
    }
    
    public static func messageReceived(by user: Username, deviceId: DeviceId, id: String) -> CypherServerEvent {
        CypherServerEvent(raw: .messageReceived(by: user, deviceId: deviceId, id: id))
    }
    
    public static func requestDeviceRegistery(_ config: UserDeviceConfig) -> CypherServerEvent {
        CypherServerEvent(raw: .requestDeviceRegistery(config))
    }
}
