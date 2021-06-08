import CypherProtocol
import Foundation
import NIO

fileprivate final class SpoofServer {
    fileprivate let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    fileprivate var onlineDevices = [SpoofTransportClient]()
    private var backlog = [DeviceId: [CypherServerEvent]]()
    private var userDevices = [Username: Set<DeviceId>]()
    fileprivate var publicKeys = [Username: UserConfig]()
    fileprivate var groupChats = [GroupChatId: GroupChatConfig]()
    fileprivate var publishedBlobs = [String: Data]()
    
    fileprivate static let local = SpoofServer()
    
    private init() {}
    
    fileprivate var hasBacklog: Bool {
        !self.backlog.values.map(\.isEmpty).reduce(true) {
            $0 && $1
        }
    }
    
    fileprivate func reset() {
        onlineDevices = []
        backlog = [:]
        userDevices = [:]
        publicKeys = [:]
        groupChats = [:]
        publishedBlobs = [:]
    }
    
    fileprivate func login(username: Username, deviceId: DeviceId) -> EventLoopFuture<SpoofTransportClient> {
        let client = SpoofTransportClient(username: username, deviceId: deviceId, server: self)
        return elg.next().makeSucceededFuture(client)
    }
    
    fileprivate func requestBacklog(username: Username, deviceId: DeviceId, into client: SpoofTransportClient) {
        if let userBacklog = backlog[deviceId] {
            for event in userBacklog {
                client.receiveServerEvent(event)
            }
        }
        
        backlog[deviceId] = nil
    }
    
    func sendEvent(_ event: CypherServerEvent, to username: Username, deviceId: DeviceId?) {
        if let deviceId = deviceId {
            for device in onlineDevices {
                if device.deviceId == deviceId {
                    device.receiveServerEvent(event)
                    return
                }
            }
            
            if backlog.keys.contains(deviceId) {
                backlog[deviceId]!.append(event)
            } else {
                backlog[deviceId] = [event]
            }
        } else if let deviceIds = userDevices[username] {
            for deviceId in deviceIds {
                self.sendEvent(event, to: username, deviceId: deviceId)
            }
        }
    }
    
    func disconnectUser(_ user: SpoofTransportClient) {
        onlineDevices.removeAll { $0.deviceId == user.deviceId }
    }
    
    func connectUser(_ user: SpoofTransportClient) {
        self.onlineDevices.append(user)
        
        if var devices = userDevices[user.username] {
            devices.insert(user.deviceId)
            userDevices[user.username] = devices
        } else {
            userDevices[user.username] = [user.deviceId]
        }
    }
}

public final class SpoofTransportClient: ConnectableCypherTransportClient {
    public static func synchronize() {
        let server = SpoofServer.local
        
        repeat {
            usleep(100)
        } while server.hasBacklog
        
        // Job queue needs to be processed, TODO
        sleep(1)
    }
    
    let username: Username
    let deviceId: DeviceId
    let eventLoop: EventLoop
    private let server: SpoofServer
    public private(set) var authenticated = AuthenticationState.unauthenticated
    public let supportsMultiRecipientMessages = true
    public weak var delegate: CypherTransportClientDelegate? {
        didSet {
            if delegate != nil {
                server.requestBacklog(username: username, deviceId: deviceId, into: self)
            }
        }
    }
    
    public static func resetServer() {
        SpoofServer.local.reset()
    }
    
    fileprivate init(username: Username, deviceId: DeviceId, server: SpoofServer) {
        self.username = username
        self.deviceId = deviceId
        self.server = server
        self.eventLoop = server.elg.next()
    }
    
    public convenience init(username: Username, deviceId: DeviceId) {
        self.init(username: username, deviceId: deviceId, server: .local)
    }
    
    public static func login(_ credentials: Credentials, eventLoop: EventLoop) -> EventLoopFuture<SpoofTransportClient> {
        SpoofServer.local.login(username: credentials.username, deviceId: credentials.deviceId)
    }
    
    public func receiveServerEvent(_ event: CypherServerEvent) {
        _ = delegate?.receiveServerEvent(event)
    }
    
    public func reconnect() -> EventLoopFuture<Void> {
        server.connectUser(self)
        authenticated = .authenticated
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        authenticated = .unauthenticated
        server.disconnectUser(self)
        return self.eventLoop.makeSucceededVoidFuture()
    }
    
    private func ifConnected<T>(_ run: () -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        if authenticated == .authenticated {
            return run()
        } else {
            return self.eventLoop.makeFailedFuture(CypherSDKError.offline)
        }
    }
    
    public func onAddContact(byUsername username: Username) -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onRemoveContact(byUsername username: Username) -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededVoidFuture()
    }
    
    public func findGroupChat(byId groupId: GroupChatId) -> EventLoopFuture<GroupChatConfig?> {
        self.eventLoop.makeSucceededFuture(server.groupChats[groupId])
    }
    
    public func sendMessageReadReceipt(byRemoteId remoteId: String, to otherUser: Username) -> EventLoopFuture<Void> {
        server.sendEvent(.messageDisplayed(by: self.username, deviceId: deviceId, id: remoteId), to: otherUser, deviceId: nil)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func sendMessageReceivedReceipt(byRemoteId remoteId: String, to otherUser: Username) -> EventLoopFuture<Void> {
        server.sendEvent(.messageReceived(by: self.username, deviceId: deviceId, id: remoteId), to: otherUser, deviceId: nil)
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func requestDeviceRegistery(_ userDeviceConfig: UserDeviceConfig) -> EventLoopFuture<Void> {
        return readKeyBundle(forUsername: self.username).flatMapThrowing { config in
            guard let masterDevice = try config.readAndValidateDevices().first(where: { device in
                device.isMasterDevice
            }) else {
                throw CypherSDKError.invalidUserConfig
            }
            
            self.server.sendEvent(
                .requestDeviceRegistery(userDeviceConfig),
                to: self.username,
                deviceId: masterDevice.deviceId
            )
        }
    }
    
    public func readKeyBundle(forUsername username: Username) -> EventLoopFuture<UserConfig> {
        guard let keys = server.publicKeys[username] else {
            return eventLoop.makeFailedFuture(CypherSDKError.missingPublicKeys)
        }
        
        return eventLoop.makeSucceededFuture(keys)
    }
    
    public func publishKeyBundle(_ keys: UserConfig) -> EventLoopFuture<Void> {
        // Fake `master device` validation
        if let existingKeys = server.publicKeys[self.username], keys.identity.data != existingKeys.identity.data {
            return eventLoop.makeFailedFuture(CypherSDKError.notMasterDevice)
        }
        
        server.publicKeys[self.username] = keys
        
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func publishBlob<C: Codable>(_ blob: C) -> EventLoopFuture<ReferencedBlob<C>> {
        do {
            let id = UUID().uuidString.lowercased()
            let resolved = ReferencedBlob(id: id, blob: blob)
            server.publishedBlobs[id] = try BSONEncoder().encode(blob).makeData()
            return eventLoop.makeSucceededFuture(resolved)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }
    
    public func readPublishedBlob<C: Codable>(byId id: String, as type: C.Type) -> EventLoopFuture<ReferencedBlob<C>?> {
        do {
            guard let blob = server.publishedBlobs[id] else {
                return eventLoop.makeSucceededFuture(nil)
            }
            
            let value = try BSONDecoder().decode(type, from: Document(data: blob))
            return eventLoop.makeSucceededFuture(ReferencedBlob(id: id, blob: value))
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }
    
    public func sendMessage(_ message: RatchetedCypherMessage, toUser otherUser: Username, otherUserDeviceId: DeviceId, messageId: String) -> EventLoopFuture<Void> {
        server.sendEvent(
            .messageSent(
                message,
                id: messageId,
                byUser: self.username,
                deviceId: deviceId
            ),
            to: otherUser,
            deviceId: otherUserDeviceId
        )
        return eventLoop.makeSucceededVoidFuture()
    }
    
    public func sendMultiRecipientMessage(
        _ message: MultiRecipientCypherMessage,
        messageId: String
    ) -> EventLoopFuture<Void> {
        for recipient in message.keys {
            server.sendEvent(
                .multiRecipientMessageSent(
                    message,
                    id: messageId,
                    byUser: self.username,
                    deviceId: deviceId
                ),
                to: recipient.user,
                deviceId: recipient.deviceId
            )
        }
        
        return eventLoop.makeSucceededVoidFuture()
    }
}
