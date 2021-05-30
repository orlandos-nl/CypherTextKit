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

public protocol CypherServerTransportClient: AnyObject {
    /// The delegate receives incoming events from the server. MUST be `weak`.
    var delegate: CypherTransportClientDelegate? { get set }
    
    /// `true` when logged in, `false` on incorrect login, `nil` when no server request has been executed yet
    var authenticated: AuthenticationState { get }
    
    /// When `true`, the CypherMessenger's internals may call the `sendMultiRecipientMessage` method.
    /// Supporting MultiRecipient Messages allows the app to expend less data uploading files to multiple recipients.
    var supportsMultiRecipientMessages: Bool { get }
    
    func reconnect() -> EventLoopFuture<Void>
    func disconnect() -> EventLoopFuture<Void>
    
    func sendMessageReadReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void>
    func sendMessageReceivedReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void>
    
    func requestDeviceRegistery(_ config: UserDeviceConfig) -> EventLoopFuture<Void>
    
    /// Reads the Config published or shared by another user. This config is commonly fetched from a shared backend. However, alternative routes of fetching key bundles is possible _and_ permitted.
    /// Other user's config files change when the device list changes.
    func readKeyBundle(forUsername username: Username) -> EventLoopFuture<UserConfig>
    
    /// Published the user's key bundle so it can be fetched by other users. While this is commonly published to a backend, this could also be stored & exported as a form of "Contact Card" blob.
    /// Please note that with multi device support enabled, each change to the device list should be known to other users.
    func publishKeyBundle(_ data: UserConfig) -> EventLoopFuture<Void>
    
    func publishBlob<C: Codable>(_ blob: C) -> EventLoopFuture<ReferencedBlob<C>>
    func readPublishedBlob<C: Codable>(byId id: String, as type: C.Type) -> EventLoopFuture<ReferencedBlob<C>?>
    
    func sendMessage(_ message: RatchetedCypherMessage, toUser username: Username, otherUserDeviceId: DeviceId, messageId: String) -> EventLoopFuture<Void>
    
    /// Sends a single blob, targeted at multiple users. The backend _may_ erase any `ContainerKey` not targeted at the recipeint, before sending it to the other client.
    /// MultiRecipeitnMessages are commonly used in multi-device or group chat scenarios, where a large blob is sent to many devices.
    /// If `supportsMultiRecipientMessages` is `false`, this method will not be called. `sendMesasge` will be called multiple times instead.
    func sendMultiRecipientMessage(_ message: MultiRecipientCypherMessage, messageId: String) -> EventLoopFuture<Void>
}

public protocol ConnectableCypherTransportClient: CypherServerTransportClient {
    static func login(_ credentials: Credentials, eventLoop: EventLoop) -> EventLoopFuture<Self>
}

public protocol CypherTransportClientDelegate: AnyObject {
    func receiveServerEvent(_ event: CypherServerEvent) -> EventLoopFuture<Void>
}

public enum CypherServerEvent {
    case multiRecipientMessageSent(MultiRecipientCypherMessage, id: String, byUser: Username, deviceId: DeviceId)
    case messageSent(RatchetedCypherMessage, id: String, byUser: Username, deviceId: DeviceId)
    case messageDisplayed(by: Username, deviceId: DeviceId, id: String)
    case messageReceived(by: Username, deviceId: DeviceId, id: String)
    case requestDeviceRegistery(UserDeviceConfig)
}
