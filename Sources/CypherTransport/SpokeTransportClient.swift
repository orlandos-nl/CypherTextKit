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
    
    func reconnect() -> EventLoopFuture<Void>
    func disconnect() -> EventLoopFuture<Void>
    
    func sendMessageReadReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void>
    func sendMessageReceivedReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void>
    
    func requestDeviceRegistery(_ config: UserDeviceConfig) -> EventLoopFuture<Void>
    
    func readKeyBundle(forUsername username: Username) -> EventLoopFuture<UserConfig>
    func publishKeyBundle(_ data: UserConfig) -> EventLoopFuture<Void>
    
    func publishBlob(_ data: Signed<Data>) -> EventLoopFuture<String>
    func readPublishedBlob(byId id: String) -> EventLoopFuture<Signed<Data>?>
    
    func sendMessage(_ message: RatchetedCypherMessage, toUser username: Username, otherUserDeviceId: DeviceId, messageId: String) -> EventLoopFuture<Void>
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
