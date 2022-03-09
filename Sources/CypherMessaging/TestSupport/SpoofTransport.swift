import CypherProtocol
import Foundation
import NIO

public enum SpoofTransportClientSettings {
    public enum PacketType {
        case readReceipt(remoteId: String, otherUser: Username)
        case receiveReceipt(remoteId: String, otherUser: Username)
        case deviceRegistery
        case readKeyBundle(username: Username)
        case publishKeyBundle
        case publishBlob
        case readBlob(id: String)
        case sendMessage(messageId: String)
    }
    
    public static var isOffline = false
    public static var shouldDropPacket: @Sendable @CryptoActor (Username, PacketType) async throws -> () = { _, _  in }
}

fileprivate final class SpoofServer {
    fileprivate let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    fileprivate var onlineDevices = [SpoofTransportClient]()
    private var backlog = [DeviceId: [CypherServerEvent]]()
    private var userDevices = [Username: Set<DeviceId>]()
    fileprivate var publicKeys = [Username: UserConfig]()
    fileprivate var groupChats = [GroupChatId: GroupChatConfig]()
    fileprivate var publishedBlobs = [String: Data]()
    fileprivate var isDoneNotifications = [EventLoopPromise<Void>]()
    
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
    
    fileprivate func login(username: Username, deviceId: DeviceId) async throws -> SpoofTransportClient {
        SpoofTransportClient(username: username, deviceId: deviceId, server: self)
    }
    
    fileprivate func requestBacklog(username: Username, deviceId: DeviceId, into client: SpoofTransportClient) async throws {
        if let userBacklog = backlog[deviceId] {
            for event in userBacklog {
                try await client.receiveServerEvent(event)
            }
        }
        
        backlog[deviceId] = nil
        
        if !isDoneNotifications.isEmpty && !hasBacklog {
            for notification in isDoneNotifications {
                notification.succeed(())
            }
            
            isDoneNotifications = []
        }
    }
    
    func sendEvent(_ event: CypherServerEvent, to username: Username, deviceId: DeviceId?) async throws {
        if let deviceId = deviceId {
            for device in onlineDevices {
                if device.deviceId == deviceId {
                    try await device.receiveServerEvent(event)
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
                try await self.sendEvent(event, to: username, deviceId: deviceId)
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
    
    func doneProcessing() async throws -> SynchronisationResult {
        if hasBacklog {
            let el = self.elg.next()
            let promise = el.makePromise(of: Void.self)
            self.isDoneNotifications.append(promise)
            try await promise.futureResult.get()
            return .synchronised
        } else {
            return .skipped
        }
    }
}

public enum SynchronisationResult {
    case skipped, synchronised, busy
}

public final class SpoofTransportClient: ConnectableCypherTransportClient {
    public static func synchronize() async throws -> SynchronisationResult {
        try await SpoofServer.local.doneProcessing()
    }
    
    let username: Username
    let deviceId: DeviceId
    private let server: SpoofServer
    public private(set) var authenticated = AuthenticationState.unauthenticated
    public let supportsMultiRecipientMessages = true
    public var isConnected: Bool { !SpoofTransportClientSettings.isOffline }
    public weak var delegate: CypherTransportClientDelegate?
    
    public func setDelegate(to delegate: CypherTransportClientDelegate) async throws {
        self.delegate = delegate
        try await server.requestBacklog(username: username, deviceId: deviceId, into: self)
    }
    
    public static func resetServer() {
        SpoofServer.local.reset()
    }
    
    fileprivate init(username: Username, deviceId: DeviceId, server: SpoofServer) {
        self.username = username
        self.deviceId = deviceId
        self.server = server
    }
    
    public convenience init(username: Username, deviceId: DeviceId) {
        self.init(username: username, deviceId: deviceId, server: .local)
    }
    
    public static func login(_ request: TransportCreationRequest) async throws -> SpoofTransportClient {
        return try await SpoofServer.local.login(username: request.username, deviceId: request.deviceId)
    }
    
    public func receiveServerEvent(_ event: CypherServerEvent) async throws {
        _ = try await delegate?.receiveServerEvent(event)
    }
    
    public func reconnect() async throws {
        if SpoofTransportClientSettings.isOffline {
            throw SpoofP2PTransportError.disconnected
        }
        
        server.connectUser(self)
        authenticated = .authenticated
    }
    
    public func disconnect() async throws {
        authenticated = .unauthenticated
        server.disconnectUser(self)
    }
    
    public func sendMessageReadReceipt(byRemoteId remoteId: String, to otherUser: Username) async throws {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .readReceipt(remoteId: remoteId, otherUser: otherUser)
        )
        try await server.sendEvent(.messageDisplayed(by: self.username, deviceId: deviceId, id: remoteId), to: otherUser, deviceId: nil)
    }
    
    public func sendMessageReceivedReceipt(byRemoteId remoteId: String, to otherUser: Username) async throws {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .receiveReceipt(remoteId: remoteId, otherUser: otherUser)
        )
        try await server.sendEvent(.messageReceived(by: self.username, deviceId: deviceId, id: remoteId), to: otherUser, deviceId: nil)
    }
    
    public func requestDeviceRegistery(_ userDeviceConfig: UserDeviceConfig) async throws {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .deviceRegistery
        )
        let config = try await readKeyBundle(forUsername: self.username)
        
        guard let masterDevice = try config.readAndValidateDevices().first(where: { device in
            device.isMasterDevice
        }) else {
            throw CypherSDKError.invalidUserConfig
        }
        
        try await self.server.sendEvent(
            .requestDeviceRegistery(userDeviceConfig),
            to: self.username,
            deviceId: masterDevice.deviceId
        )
    }
    
    public func readKeyBundle(forUsername username: Username) async throws -> UserConfig {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .readKeyBundle(username: username)
        )
        
        guard let keys = server.publicKeys[username] else {
            throw CypherSDKError.missingPublicKeys
        }
        
        return keys
    }
    
    public func publishKeyBundle(_ keys: UserConfig) async throws {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .publishKeyBundle
        )
        
        // Fake `master device` validation
        if let existingKeys = server.publicKeys[self.username], keys.identity.data != existingKeys.identity.data {
            throw CypherSDKError.notMasterDevice
        }
        
        server.publicKeys[self.username] = keys
    }
    
    public func publishBlob<C: Codable>(_ blob: C) async throws -> ReferencedBlob<C> {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .publishBlob
        )
        let id = UUID().uuidString.lowercased()
        let resolved = ReferencedBlob(id: id, blob: blob)
        server.publishedBlobs[id] = try BSONEncoder().encode(blob).makeData()
        return resolved
    }
    
    public func readPublishedBlob<C: Codable>(byId id: String, as type: C.Type) async throws -> ReferencedBlob<C>? {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .readBlob(id: id)
        )
        guard let blob = server.publishedBlobs[id] else {
            return nil
        }
        
        let value = try BSONDecoder().decode(type, from: Document(data: blob))
        return ReferencedBlob(id: id, blob: value)
    }
    
    public func sendMessage(
        _ message: RatchetedCypherMessage,
        toUser otherUser: Username,
        otherUserDeviceId: DeviceId,
        pushType: PushType,
        messageId: String
    ) async throws {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .sendMessage(messageId: messageId)
        )
        try await server.sendEvent(
            .messageSent(
                message,
                id: messageId,
                byUser: self.username,
                deviceId: deviceId
            ),
            to: otherUser,
            deviceId: otherUserDeviceId
        )
    }
    
    public func sendMultiRecipientMessage(
        _ message: MultiRecipientCypherMessage,
        pushType: PushType,
        messageId: String
    ) async throws {
        if !isConnected {
            throw CypherSDKError.offline
        }
        
        try await SpoofTransportClientSettings.shouldDropPacket(
            self.username,
            .sendMessage(messageId: messageId)
        )
        for recipient in message.keys {
            try await server.sendEvent(
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
    }
}
