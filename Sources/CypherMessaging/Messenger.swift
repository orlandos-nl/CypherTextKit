@preconcurrency import BSON
@preconcurrency import Foundation
import Crypto
import NIO
import CypherProtocol

public enum DeviceRegisteryMode: Int, Codable, Sendable {
    case masterDevice, childDevice, unregistered
}

@globalActor public final actor CypherTextKitActor {
    public static let shared = CypherTextKitActor()
    
    private init() {}
}

public typealias CryptoActor = CypherTextKitActor
typealias JobQueueActor = CypherTextKitActor

internal struct _CypherMessengerConfig: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case databaseEncryptionKey = "a"
        case deviceKeys = "b"
        case username = "c"
        case registeryMode = "d"
        case custom = "e"
        case deviceIdentityId = "f"
        case lastKnownUserConfig = "g"
    }
    
    let databaseEncryptionKey: Data
    let deviceKeys: DevicePrivateKeys
    let username: Username
    var registeryMode: DeviceRegisteryMode
    var custom: Document
    let deviceIdentityId: Int
    var lastKnownUserConfig: UserConfig?
}

enum RekeyState: Sendable {
    case rekey, next
}

/// Provided by CypherMessenger to a factory (function) so that it can create a Transport Client to the app's servers
public struct TransportCreationRequest: Sendable {
    public let username: Username
    public let deviceId: DeviceId
    public let userConfig: UserConfig
    internal let signingIdentity: PrivateSigningKey
    public var identity: PublicSigningKey { signingIdentity.publicKey }
    
    /// Can be used to sign information in name of the logged in CypherMessenger
    /// For example; to self-sign a JWT Token, assuming the server has registered the user's public keys
    public func signature<D: DataProtocol>(for data: D) throws -> Data {
        try signingIdentity.signature(for: data)
    }
}

public struct ContactCard: Codable, Sendable {
    public let username: Username
    public let config: UserConfig
}

/// The representation of a P2PSession with another device
///
/// Peer-to-peer sessions are used to communicate directly with another device
/// They can rely on a custom otransport implementation, leveraging network or platform features
@available(macOS 10.15, iOS 13, *)
internal struct P2PSession {
    /// The connected device's known username
    /// Multiple devics may belong to the same username
    let username: Username
    
    /// The specific device, which is registered ot `username`
    let deviceId: DeviceId
    
    /// The other device's publicKey
    let publicKey: PublicKey
    
    /// The other device's signingKey, used to verify that data originates from that device
    let identity: PublicSigningKey
    
    /// A P2PClient object, which you can use to communicate with the remote device
    let client: P2PClient
    
    /// The transport client used by P2PClient
    let transport: P2PTransportClient
    
    @CryptoActor init(
        peer: Peer,
        transport: P2PTransportClient,
        client: P2PClient
    ) {
        self.username = peer.username
        self.deviceId = peer.deviceId
        self.publicKey = peer.publicKey
        self.identity = peer.identity
        self.transport = transport
        self.client = client
    }
    
    @CryptoActor init(
        deviceIdentity: _DecryptedModel<DeviceIdentityModel>,
        transport: P2PTransportClient,
        client: P2PClient
    ) {
        self.username = deviceIdentity.username
        self.deviceId = deviceIdentity.deviceId
        self.publicKey = deviceIdentity.publicKey
        self.identity = deviceIdentity.identity
        self.transport = transport
        self.client = client
    }
}

/// This actor stores all mutable shared state for a CypherMessenger instance
fileprivate final class CypherMessengerActor {
    @CypherTextKitActor var config: _CypherMessengerConfig
    @CypherTextKitActor var p2pSessions = [P2PSession]()
    @CypherTextKitActor var appPassword: String
    let cachedStore: _CypherMessengerStoreCache
    
    internal init(config: _CypherMessengerConfig, cachedStore: _CypherMessengerStoreCache, appPassword: String) {
        self.config = config
        self.p2pSessions = []
        self.appPassword = appPassword
        self.cachedStore = cachedStore
    }
    
    @CypherTextKitActor func updateConfig(_ run: @Sendable (inout _CypherMessengerConfig) -> ()) async throws {
        let salt = try await self.cachedStore.readLocalDeviceSalt()
        let appEncryptionKey = CypherMessenger.formAppEncryptionKey(appPassword: appPassword, salt: salt)
        run(&config)
        let encryptedConfig = try Encrypted(config, encryptionKey: appEncryptionKey)
        try await self.cachedStore.writeLocalDeviceConfig(encryptedConfig.makeData())
    }
    
    @CypherTextKitActor func changeAppPassword(to appPassword: String) async throws {
        let salt = try await self.cachedStore.readLocalDeviceSalt()
        let appEncryptionKey = CypherMessenger.formAppEncryptionKey(appPassword: appPassword, salt: salt)
        
        let encryptedConfig = try Encrypted(self.config, encryptionKey: appEncryptionKey)
        let data = encryptedConfig.makeData()
        try await self.cachedStore.writeLocalDeviceConfig(data)
        self.appPassword = appPassword
    }
    
    @CypherTextKitActor var isSetupCompleted: Bool {
        switch config.registeryMode {
        case .unregistered:
            return false
        case .childDevice, .masterDevice:
            return true
        }
    }
    
    @CypherTextKitActor public func sign<T: Codable>(_ value: T) throws -> Signed<T> {
        try Signed(value, signedBy: config.deviceKeys.identity)
    }
    
    @CypherTextKitActor public func writeCustomConfig(_ custom: Document) async throws {
        let salt = try await self.cachedStore.readLocalDeviceSalt()
        let appEncryptionKey = CypherMessenger.formAppEncryptionKey(appPassword: self.appPassword, salt: salt)
        var newConfig = self.config
        newConfig.custom = custom
        let encryptedConfig = try Encrypted(newConfig, encryptionKey: appEncryptionKey)
        try await self.cachedStore.writeLocalDeviceConfig(encryptedConfig.makeData())
        self.config = newConfig
    }
    
    @CypherTextKitActor func closeP2PConnection(_ connection: P2PTransportClient) async {
        debugLog("Removing P2P session from active pool")
        guard let index = p2pSessions.firstIndex(where: {
            $0.transport === connection
        }) else {
            return
        }
        
        let session = p2pSessions.remove(at: index)
        return await session.client.disconnect()
    }
    
    @CypherTextKitActor func registerSession(_ session: P2PSession) {
        p2pSessions.append(session)
    }
}

/// A CypherMessenger is the heart of CypherTextKit Framework, similar to an "Application" class.
/// CypherMessenger is responsible for orchestrating end-to-end encrypted communication of any kind.
///
/// CypherMessenger can be created as a singleton, but multiple clients in the same process is supported.
@available(macOS 10.15, iOS 13, *)
public final class CypherMessenger: CypherTransportClientDelegate, P2PTransportClientDelegate, P2PTransportFactoryDelegate, @unchecked Sendable {
    @CypherTextKitActor public func createLocalDeviceAdvertisement() async throws -> P2PAdvertisement {
        let advertisement = P2PAdvertisement.Advertisement(
            origin: Peer(
                username: username,
                deviceConfig: UserDeviceConfig(
                    deviceId: deviceId,
                    identity: state.config.deviceKeys.identity.publicKey,
                    publicKey: state.config.deviceKeys.privateKey.publicKey,
                    isMasterDevice: state.config.registeryMode == .masterDevice
                )
            )
        )
        
        return try await P2PAdvertisement(advertisement: sign(advertisement))
    }
    
    internal let eventLoop: EventLoop
    private(set) var jobQueue: JobQueue!
    private var inactiveP2PSessionsTimeout: Int? = 30
    internal let deviceIdentityId: Int
    fileprivate let state: CypherMessengerActor
    let p2pFactories: [P2PTransportClientFactory]
    internal let eventHandler: CypherMessengerEventHandler
    internal let cachedStore: _CypherMessengerStoreCache
    internal let databaseEncryptionKey: SymmetricKey
    
    /// All rediscovered usernames during this session
    /// Will reset next boot
    @CryptoActor internal var rediscoveredUsernames = Set<Username>()
    
    /// The TransportClient implementation provided to CypherTextKit for this CypherMessenger to communicate through
    public let transport: CypherServerTransportClient
    
    public var isOnline: Bool { transport.isConnected }
    public var authenticated: AuthenticationState { transport.authenticated }
    public var canBroadcastInMesh: Bool {
        for factory in p2pFactories {
            if factory.isMeshEnabled {
                return true
            }
        }
        
        return false
    }
    
    /// The username that this device is registered to
    public let username: Username
    
    /// The deviceId which, together with te username, identifies a registered device
    public let deviceId: DeviceId
    
    private init(
        appPassword: String,
        eventHandler: CypherMessengerEventHandler,
        config: _CypherMessengerConfig,
        database: CypherMessengerStore,
        p2pFactories: [P2PTransportClientFactory],
        transport: CypherServerTransportClient
    ) async throws {
        self.eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.eventHandler = eventHandler
        self.username = config.username
        self.deviceId = config.deviceKeys.deviceId
        self.deviceIdentityId = config.deviceIdentityId
        self.cachedStore = _CypherMessengerStoreCache(base: database)
        self.transport = transport
        self.databaseEncryptionKey = SymmetricKey(data: config.databaseEncryptionKey)
        self.p2pFactories = p2pFactories
        self.state = CypherMessengerActor(
            config: config,
            cachedStore: cachedStore,
            appPassword: appPassword
        )
        self.jobQueue = JobQueue(messenger: self, database: self.cachedStore, databaseEncryptionKey: self.databaseEncryptionKey)
        
        try await jobQueue.loadJobs()
        try await self.transport.setDelegate(to: self)
        
        if transport.authenticated == .unauthenticated {
            Task.detached {
                try await self.transport.reconnect()
                await self.jobQueue.startRunningTasks()
            }
        }
        
        await jobQueue.resume()
        
        for factory in p2pFactories {
            factory.delegate = self
        }
        
        // Ensure this device knows if it's registered or not
        if config.registeryMode == .unregistered {
            Task { @CypherTextKitActor in
                let bundle = try await transport.readKeyBundle(forUsername: self.username)
                try await self.updateConfig { appConfig in
                    appConfig.lastKnownUserConfig = bundle
                }
                for device in try bundle.readAndValidateDevices() {
                    if device.deviceId == self.deviceId {
                        try await self.updateConfig { $0.registeryMode = device.isMasterDevice ? .masterDevice : .childDevice }
                        return
                    }
                }
            }
        } else if transport.isConnected, config.lastKnownUserConfig == nil {
            let bundle = try await transport.readKeyBundle(forUsername: config.username)
            try await self.updateConfig { appConfig in
                appConfig.lastKnownUserConfig = bundle
            }
        }
    }
    
    /// Initializes and registers a new messenger. This generates a new private key.
    ///
    ///  - Parameters:
    ///     - username: The username which identifies this user.
    ///     - appPassword: The password which is used to encrypt the database models.
    ///     - usingTransport: A method that CypherTextKit can use to create a transport method with a server, of which the implementation is provided by your application.
    ///     - p2pFactories: When provided, these factories are used when attempting to create a direct connection with another user's device(s). This can then be used for exchanging real-time information such as typing indicators, or simply improving the latency between two chatting devices.
    ///     - database: An implementation of persistent storage for database models.
    ///     - eventHandler: A delegate which can control certain behaviour, or simply respond to changes in datasets.
    ///
    /// Implementations that do not (yet) wish to enforce an app password upon users can resort to an empty string `""` for the appPassword.
    public static func registerMessenger<
        Transport: CypherServerTransportClient
    >(
        username: Username,
        appPassword: String,
        usingTransport createTransport: @escaping (TransportCreationRequest) async throws -> Transport,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler
    ) async throws -> CypherMessenger {
        let deviceId = DeviceId()
        let databaseEncryptionKey = SymmetricKey(size: .bits256)
        let databaseEncryptionKeyData = databaseEncryptionKey.withUnsafeBytes { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
        
        let deviceKeys = DevicePrivateKeys(deviceId: deviceId)
        let userConfig = try UserConfig(
            mainDevice: deviceKeys,
            otherDevices: []
        )
        var config = _CypherMessengerConfig(
            databaseEncryptionKey: databaseEncryptionKeyData,
            deviceKeys: deviceKeys,
            username: username,
            registeryMode: .unregistered,
            custom: [:],
            deviceIdentityId: .random(in: 1 ..< .max),
            lastKnownUserConfig: userConfig
        )
        
        let salt = try await database.readLocalDeviceSalt()
        let appEncryptionKey = Self.formAppEncryptionKey(
            appPassword: appPassword,
            salt: salt
        )
        
        var encryptedConfig = try Encrypted(config, encryptionKey: appEncryptionKey)
        
        let transportRequest = TransportCreationRequest(
            username: username,
            deviceId: deviceId,
            userConfig: userConfig,
            signingIdentity: config.deviceKeys.identity
        )
        
        let transport = try await createTransport(transportRequest)
        
        do {
            let existingKeys = try await transport.readKeyBundle(forUsername: username)
            // Existing config found, this is a new device that needs to be registered
            let messenger = try await CypherMessenger(
                appPassword: appPassword,
                eventHandler: eventHandler,
                config: config,
                database: database,
                p2pFactories: p2pFactories,
                transport: transport
            )
            
            if existingKeys.identity.data == config.deviceKeys.identity.publicKey.data {
                try await database.writeLocalDeviceConfig(encryptedConfig.makeData())
                return messenger
            }
            
            let metadata = UserDeviceConfig(
                deviceId: config.deviceKeys.deviceId,
                identity: config.deviceKeys.identity.publicKey,
                publicKey: config.deviceKeys.privateKey.publicKey,
                isMasterDevice: false
            )
            
            try await database.writeLocalDeviceConfig(encryptedConfig.makeData())
            try await transport.requestDeviceRegistery(metadata)
            return messenger
        } catch {
            config.registeryMode = .masterDevice
            
            encryptedConfig = try Encrypted(config, encryptionKey: appEncryptionKey)
            try await database.writeLocalDeviceConfig(encryptedConfig.makeData())
            
            guard transport.isConnected || transport.supportsDelayedRegistration else {
                throw CypherSDKError.cannotRegisterDeviceConfig
            }
            
            if transport.isConnected {
                try await transport.publishKeyBundle(userConfig)
            }
            
            return try await CypherMessenger(
                appPassword: appPassword,
                eventHandler: eventHandler,
                config: config,
                database: database,
                p2pFactories: p2pFactories,
                transport: transport
            )
        }
    }
    
    /// Initializes and registers a new messenger. This generates a new private key.
    ///
    ///  - Parameters:
    ///     - username: The username which identifies this user.
    ///     - appPassword: The password which is used to encrypt the database models.
    ///     - usingTransport: A Transport Factory that CypherTextKit can use to create a transport method with a server, of which the implementation is provided by your application.
    ///     - p2pFactories: When provided, these factories are used when attempting to create a direct connection with another user's device(s). This can then be used for exchanging real-time information such as typing indicators, or simply improving the latency between two chatting devices.
    ///     - database: An implementation of persistent storage for database models.
    ///     - eventHandler: A delegate which can control certain behaviour, or simply respond to changes in datasets.
    ///
    /// Implementations that do not (yet) wish to enforce an app password upon users can resort to an empty string `""` for the appPassword.
    public static func registerMessenger<
        Transport: ConnectableCypherTransportClient
    >(
        username: Username,
        authenticationMethod: AuthenticationMethod,
        appPassword: String,
        usingTransport: Transport.Type,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler
    ) async throws -> CypherMessenger {
        try await Self.registerMessenger(
            username: username,
            appPassword: appPassword,
            usingTransport: { request in
                try await Transport.login(request)
            },
            p2pFactories: p2pFactories,
            database: database,
            eventHandler: eventHandler
        )
    }
    
    /// Resumes a suspended CypherMessenger from the `database`
    ///
    ///  - Parameters:
    ///     - appPassword: The password which is used to encrypt the database models.
    ///     - usingTransport: A method that CypherTextKit can use to create a transport method with a server, of which the implementation is provided by your application.
    ///     - p2pFactories: When provided, these factories are used when attempting to create a direct connection with another user's device(s). This can then be used for exchanging real-time information such as typing indicators, or simply improving the latency between two chatting devices.
    ///     - database: An implementation of persistent storage for database models.
    ///     - eventHandler: A delegate which can control certain behaviour, or simply respond to changes in datasets.
    ///
    /// Implementations that do not (yet) wish to enforce an app password upon users can resort to an empty string `""` for the appPassword.
    public static func resumeMessenger<
        Transport: ConnectableCypherTransportClient
    >(
        appPassword: String,
        usingTransport createTransport: Transport.Type,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler
    ) async throws -> CypherMessenger {
        try await resumeMessenger(
            appPassword: appPassword,
            usingTransport: { request in
                try await Transport.login(request)
            },
            p2pFactories: p2pFactories,
            database: database,
            eventHandler: eventHandler
        )
    }
    
    /// Resumes a suspended CypherMessenger from the `database`
    ///
    ///  - Parameters:
    ///     - appPassword: The password which is used to encrypt the database models.
    ///     - usingTransport: A Transport Factory that CypherTextKit can use to create a transport method with a server, of which the implementation is provided by your application.
    ///     - p2pFactories: When provided, these factories are used when attempting to create a direct connection with another user's device(s). This can then be used for exchanging real-time information such as typing indicators, or simply improving the latency between two chatting devices.
    ///     - database: An implementation of persistent storage for database models.
    ///     - eventHandler: A delegate which can control certain behaviour, or simply respond to changes in datasets.
    ///
    /// Implementations that do not (yet) wish to enforce an app password upon users can resort to an empty string `""` for the appPassword.
    public static func resumeMessenger<
        Transport: CypherServerTransportClient
    >(
        appPassword: String,
        usingTransport createTransport: @escaping (TransportCreationRequest) async throws -> Transport,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler
    ) async throws -> CypherMessenger {
        let salt = try await database.readLocalDeviceSalt()
        let encryptionKey = Self.formAppEncryptionKey(appPassword: appPassword, salt: salt)
        
        let data = try await database.readLocalDeviceConfig()
        let box = try AES.GCM.SealedBox(combined: data)
        let encryptedConfig = Encrypted<_CypherMessengerConfig>(representing: box)
        let config = try encryptedConfig.decrypt(using: encryptionKey)
        
        let transportRequest = try TransportCreationRequest(
            username: config.username,
            deviceId: config.deviceKeys.deviceId,
            userConfig: config.lastKnownUserConfig ?? UserConfig(
                mainDevice: config.deviceKeys,
                otherDevices: []
            ),
            signingIdentity: config.deviceKeys.identity
        )
        
        let transport = try await createTransport(transportRequest)
        
        return try await CypherMessenger(
            appPassword: appPassword,
            eventHandler: eventHandler,
            config: config,
            database: database,
            p2pFactories: p2pFactories,
            transport: transport
        )
    }
    
    fileprivate static func formAppEncryptionKey(appPassword: String, salt: String) -> SymmetricKey {
        let inputKey = SymmetricKey(data: SHA512.hash(data: appPassword.data(using: .utf8)!))
        return HKDF<SHA512>.deriveKey(inputKeyMaterial: inputKey, salt: salt.data(using: .utf8)!, outputByteCount: 256 / 8)
    }
    
    /// Verifies that this client uses the `appPassword` to unlock the app..
    /// Useful when you want to keep the CypherMessenger instance active in the background, but want to verify the user's password before showing them the UI.
    public func verifyAppPassword(matches appPassword: String) async -> Bool {
        do {
            let salt = try await self.cachedStore.readLocalDeviceSalt()
            let appEncryptionKey = Self.formAppEncryptionKey(appPassword: appPassword, salt: salt)
                
            let data = try await self.cachedStore.readLocalDeviceConfig()
            let box = try AES.GCM.SealedBox(combined: data)
            let config = Encrypted<_CypherMessengerConfig>(representing: box)
            try config.canDecrypt(using: appEncryptionKey)
            return true
        } catch {
            return false
        }
    }
    
    @CryptoActor public func importContactCard(
        _ card: ContactCard
    ) async throws {
        let knownDevices = try await _fetchKnownDeviceIdentities(for: card.username)
        guard knownDevices.isEmpty else {
            throw CypherSDKError.cannotImportExistingContact
        }
        
        try await _processDeviceConfig(
            card.config,
            forUername: card.username,
            knownDevices: []
        )
    }
    
    @CypherTextKitActor public func createContactCard() async throws -> ContactCard {
        if state.config.registeryMode == .masterDevice {
            let otherDevices = try await _fetchKnownDeviceIdentities(for: self.username)
            
            return ContactCard(
                username: self.username,
                config: try UserConfig(
                    mainDevice: state.config.deviceKeys,
                    otherDevices: otherDevices.map { device in
                        return UserDeviceConfig(
                            deviceId: device.deviceId,
                            identity: device.identity,
                            publicKey: device.publicKey,
                            isMasterDevice: false
                        )
                    }
                )
            )
        } else if let lastKnownUserConfig = state.config.lastKnownUserConfig {
            return ContactCard(
                username: self.username,
                config: lastKnownUserConfig
            )
        } else {
            let bundle = try await transport.readKeyBundle(forUsername: self.username)
            try await self.updateConfig { appConfig in
                appConfig.lastKnownUserConfig = bundle
            }
            
            return ContactCard(
                username: self.username,
                config: bundle
            )
        }
    }
    
    internal func updateConfig(_ run: @Sendable (inout _CypherMessengerConfig) -> ()) async throws {
        try await state.updateConfig(run)
    }
    
    /// Used to change the `appPassword`. The new `appPassword` must be provided for `verifyAppPassword` and `resumeMessenger`.
    public func changeAppPassword(to appPassword: String) async throws {
        try await state.changeAppPassword(to: appPassword)
    }
    
    /// Creates a request for a **master device** to add this device to their account
    ///
    /// - Parameters:
    ///     - isMasterDevice: Requests the other device to add this device as a master, allowing this device to add more clients as well.
    ///
    /// The client is responsible for transporting the UserDeviceConfig to another device, for example through a QR code.
    /// The master device must then call `addDevice` with this request.
    public func createDeviceRegisteryRequest(isMasterDevice: Bool = false) async throws -> UserDeviceConfig? {
        guard await registeryMode == .unregistered else {
            // Cannot register, already registered
            return nil
        }
        
        if try await isRegisteredOnline() {
            try await updateConfig { appConfig in
                appConfig.registeryMode = .childDevice
            }
            return nil
        }
        
        return await UserDeviceConfig(
            deviceId: deviceId,
            identity: state.config.deviceKeys.identity.publicKey,
            publicKey: state.config.deviceKeys.privateKey.publicKey,
            isMasterDevice: isMasterDevice
        )
    }
    
    @CypherTextKitActor public var isPasswordProtected: Bool {
        !state.appPassword.isEmpty
    }
    
    public func checkSetupCompleted() async -> Bool {
        await state.isSetupCompleted
    }
    
    public func isRegisteredOnline() async throws -> Bool {
        let config = try await transport.readKeyBundle(forUsername: self.username)
        let devices = try config.readAndValidateDevices()
        return devices.contains(where: { $0.deviceId == self.deviceId })
    }
    
    /// Mainly used by test suties, to ensure all outstanding work is finished.
    /// This is handy when you're simulating communication, but want to delay assertions until this CypherMessenger has processed all outstanding work.
    public func processJobQueue() async throws -> SynchronisationResult {
        try await jobQueue.awaitDoneProcessing()
    }
    
    public func resumeJobQueue() async {
        await jobQueue.resume()
    }
    
    // TODO: Make internal
    /// Internal API that CypherMessenger uses to read information from Transport Clients
    public func receiveServerEvent(_ event: CypherServerEvent) async throws {
        switch event.raw {
        case let .multiRecipientMessageSent(message, id: messageId, byUser: sender, deviceId: deviceId, createdAt: createdAt):
            return try await self.jobQueue.queueTask(
                CypherTask.processMultiRecipientMessage(
                    ReceiveMultiRecipientMessageTask(
                        message: message,
                        messageId: messageId,
                        sender: sender,
                        deviceId: deviceId,
                        createdAt: createdAt
                    )
                )
            )
        case let .messageSent(message, id: messageId, byUser: sender, deviceId: deviceId, createdAt: createdAt):
            // TODO: Server- or even origin-defined creation date
            return try await self.jobQueue.queueTask(
                CypherTask.processMessage(
                    ReceiveMessageTask(
                        message: message,
                        messageId: messageId,
                        sender: sender,
                        deviceId: deviceId,
                        createdAt: createdAt
                    )
                )
            )
        case let .messageDisplayed(by: recipient, deviceId: deviceId, id: messageId):
            return try await self.jobQueue.queueTask(
                CypherTask.receiveMessageDeliveryStateChangeTask(
                    ReceiveMessageDeliveryStateChangeTask(
                        messageId: messageId,
                        sender: recipient,
                        deviceId: deviceId,
                        newState: .read
                    )
                )
            )
        case let .messageReceived(by: recipient, deviceId: deviceId, id: messageId):
            return try await self.jobQueue.queueTask(
                CypherTask.receiveMessageDeliveryStateChangeTask(
                    ReceiveMessageDeliveryStateChangeTask(
                        messageId: messageId,
                        sender: recipient,
                        deviceId: deviceId,
                        newState: .received
                    )
                )
            )
        case let .requestDeviceRegistery(deviceConfig):
            guard await state.config.registeryMode == .masterDevice, !deviceConfig.isMasterDevice else {
                debugLog("Received message intented for master device")
                throw CypherSDKError.notMasterDevice
            }
            
            try await self.eventHandler.onDeviceRegisteryRequest(deviceConfig, messenger: self)
        }
    }
    
    /// Empties the CypherMessenger's caches to clear up memory.
    public func emptyCaches() async {
        await cachedStore.emptyCaches()
    }
    
    /// Adds a new device to this user's devices. This device can from now on receive all messages, and communicate in name of this user.
    @MainActor public func addDevice(_ deviceConfig: UserDeviceConfig) async throws {
        var config = try await transport.readKeyBundle(forUsername: self.username)
        guard await config.identity.data == state.config.deviceKeys.identity.publicKey.data else {
            throw CypherSDKError.corruptUserConfig
        }
        
        try config.addDeviceConfig(deviceConfig, signedWith: await state.config.deviceKeys.identity)
        try await self.transport.publishKeyBundle(config)
        let uploadedConfig = config
        try await self.updateConfig { appConfig in
            appConfig.lastKnownUserConfig = uploadedConfig
        }
        let internalConversation = try await self.getInternalConversation()
        let metadata = try BSONEncoder().encode(deviceConfig)
        try await self._createDeviceIdentity(
            from: deviceConfig,
            forUsername: self.username
        )
        
        let message = SingleCypherMessage(
            messageType: .magic,
            messageSubtype: "_/devices/announce",
            text: deviceConfig.deviceId.raw,
            metadata: metadata,
            order: 0,
            target: .currentUser
        )
        
        try await internalConversation.sendInternalMessage(message)
        
        for contact in try await listContacts() {
            try await _writeMessage(message, to: contact.username)
        }
    }
    
    @CypherTextKitActor func _writeMessageOverMesh(
        _ message: RatchetedCypherMessage,
        messageId: String,
        to recipient: Peer
    ) async throws {
        let origin = Peer(
            username: username,
            deviceConfig: UserDeviceConfig(
                deviceId: deviceId,
                identity: state.config.deviceKeys.identity.publicKey,
                publicKey: state.config.deviceKeys.privateKey.publicKey,
                isMasterDevice: state.config.registeryMode == .masterDevice
            )
        )
        
        let broadcastMessage = P2PBroadcast.Message(
            origin: origin,
            target: recipient,
            messageId: messageId,
            createdAt: Date(),
            payload: message
        )
        let signedBroadcastMessage = try await sign(broadcastMessage)
        let broadcast = P2PBroadcast(hops: 16, value: signedBroadcastMessage)
        
        for client in listOpenP2PConnections() where client.isMeshEnabled {
            Task {
                // Ignore errors
                try await client.sendMessage(.broadcast(broadcast))
            }
        }
    }
    
    func _writeMessage(
        _ message: SingleCypherMessage,
        to recipient: Username
    ) async throws {
        for device in try await _fetchDeviceIdentities(for: recipient) {
            try await _queueTask(
                .sendMessage(
                    SendMessageTask(
                        message: CypherMessage(message: message),
                        recipient: recipient,
                        recipientDeviceId: device.props.deviceId,
                        localId: nil,
                        pushType: message.preferredPushType ?? .none,
                        messageId: UUID().uuidString
                    )
                )
            )
        }
    }
    
    @CryptoActor func _withCreatedMultiRecipientMessage<T>(
        encrypting message: CypherMessage,
        forDevices devices: [_DecryptedModel<DeviceIdentityModel>],
        run: @Sendable (MultiRecipientCypherMessage) async throws -> T
    ) async throws -> T {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
        
        let messageData = try BSONEncoder().encode(message).makeData()
        let encryptedMessage = try AES.GCM.seal(messageData, using: key).combined!
        
        var keyMessages = [MultiRecipientCypherMessage.ContainerKey]()
        var rekeyDevices = [_DecryptedModel<DeviceIdentityModel>]()
        
        for device in devices {
            let keyMessage = try await device._writeWithRatchetEngine(messenger: self) { ratchetEngine, rekeyState -> MultiRecipientCypherMessage.ContainerKey in
                let ratchetMessage = try ratchetEngine.ratchetEncrypt(keyData)
                
                return try MultiRecipientCypherMessage.ContainerKey(
                    user: device.props.username,
                    deviceId: device.props.deviceId,
                    message: self._signRatchetMessage(
                        ratchetMessage,
                        rekey: rekeyState
                    )
                )
            }
            
            if keyMessage.message.rekey {
                rekeyDevices.append(device)
            }
            
            keyMessages.append(keyMessage)
        }
        
        do {
            let message = try MultiRecipientCypherMessage(
                encryptedMessage: encryptedMessage,
                signWith: state.config.deviceKeys.identity,
                keys: keyMessages
            )
            
            return try await run(message)
        } catch {
            for device in rekeyDevices {
                // Device was instantiated with a rekey, but the message wasn't sent
                // So to prevent any further confusion & issues, just reset this
                try device.updateDoubleRatchetState(to: nil)
            }
            
            throw error
        }
    }
    
    @MainActor final class ModelCache {
        private var cache = [UUID: Weak<AnyObject>]()
        @MainActor func getModel<M: Model>(ofType: M.Type, forId id: UUID) -> DecryptedModel<M>? {
            cache[id]?.object as? DecryptedModel<M>
        }
        
        @MainActor func addModel<M: Model>(_ model: DecryptedModel<M>, forId id: UUID) {
            cache[id] = Weak(object: model)
        }
    }
    
    @CryptoActor final class InternalModelCache {
        private var cache = [UUID: Weak<AnyObject>]()
        @CryptoActor func getModel<M: Model>(ofType: M.Type, forId id: UUID) -> _DecryptedModel<M>? {
            cache[id]?.object as? _DecryptedModel<M>
        }
        
        @CryptoActor func addModel<M: Model>(_ model: _DecryptedModel<M>, forId id: UUID) {
            cache[id] = Weak(object: model)
        }
    }
    
    @MainActor private let cache = ModelCache()
    @CryptoActor private let _cache = InternalModelCache()
    
    /// Decrypts a model as provided by the database
    /// It is critical to call this method for decryption for stability reasons, as CypherMessenger prevents duplicate representations of a Model from existing at the same time.
    @CryptoActor internal func _cachelessDecrypt<M: Model>(_ model: M) throws -> _DecryptedModel<M> {
        try _DecryptedModel(model: model, encryptionKey: databaseEncryptionKey)
    }
    
    /// Decrypts a model as provided by the database
    /// It is critical to call this method for decryption for stability reasons, as CypherMessenger prevents duplicate representations of a Model from existing at the same time.
    @CryptoActor func _decrypt<M: Model>(_ model: M) throws -> _DecryptedModel<M> {
        if let decrypted = _cache.getModel(ofType: M.self, forId: model.id) {
            return decrypted
        }
        
        let decrypted = try _DecryptedModel(model: model, encryptionKey: databaseEncryptionKey)
        _cache.addModel(decrypted, forId: model.id)
        return decrypted
    }
    
    /// Decrypts a model as provided by the database
    /// It is critical to call this method for decryption for stability reasons, as CypherMessenger prevents duplicate representations of a Model from existing at the same time.
    @MainActor public func decrypt<M: Model>(_ model: M) throws -> DecryptedModel<M> {
        if let decrypted = cache.getModel(ofType: M.self, forId: model.id) {
            return decrypted
        }
        
        let decrypted = try DecryptedModel(model: model, encryptionKey: databaseEncryptionKey)
        cache.addModel(decrypted, forId: model.id)
        return decrypted
    }
    
    @CryptoActor public func decryptDirectMessageNotification(
        _ message: RatchetedCypherMessage,
        senderUser username: Username,
        senderDeviceId deviceId: DeviceId
    ) async throws -> String? {
        guard
            !message.rekey,
            let deviceIdentity = try await self._fetchKnownDeviceIdentity(for: username, deviceId: deviceId),
            let ratchetState = deviceIdentity.doubleRatchet
        else {
            return nil
        }
        
        let message = try message.readAndValidate(usingIdentity: deviceIdentity.identity)
        var ratchet = DoubleRatchetHKDF(state: ratchetState, configuration: doubleRatchetConfig)
        let data = try ratchet.ratchetDecrypt(message)
        
        // Don't save the ratchet state
        let decryptedMessage = try BSONDecoder().decode(CypherMessage.self, from: Document(data: data))
        
        switch decryptedMessage.box {
        case .array(let list):
            return list.first { $0.messageType == .text }?.text
        case .single(let message):
            if message.messageType != .text || message.text.isEmpty {
                return nil
            }
            
            return message.text
        }
    }
    
    @CryptoActor public func decryptMultiRecipientMessageNotification(
        _ message: MultiRecipientCypherMessage,
        senderUser username: Username,
        senderDeviceId deviceId: DeviceId
    ) async throws -> String? {
        guard
            let foundKey = message.keys.first(where: { key in
                key.deviceId == self.deviceId && key.user == self.username
            }),
            let deviceIdentity = try await self._fetchKnownDeviceIdentity(for: username, deviceId: deviceId),
            let ratchetState = deviceIdentity.doubleRatchet
        else {
            return nil
        }
        
        let keyMessage = try foundKey.message.readAndValidate(usingIdentity: deviceIdentity.identity)
        var ratchet = DoubleRatchetHKDF(state: ratchetState, configuration: doubleRatchetConfig)
        let keyData = try ratchet.ratchetDecrypt(keyMessage)
        
        guard keyData.count == 32 else {
            throw CypherSDKError.invalidMultiRecipientKey
        }
        
        let key = SymmetricKey(data: keyData)
        
        // Don't save the ratchet state
        let decryptedMessage = try message.container.readAndValidate(
            type: CypherMessage.self,
            usingIdentity: deviceIdentity.props.identity,
            decryptingWith: key
        )
        
        switch decryptedMessage.box {
        case .array(let list):
            return list.first { $0.messageType == .text }?.text
        case .single(let message):
            if message.messageType != .text || message.text.isEmpty {
                return nil
            }
            
            return message.text
        }
    }
    
    /// Encrypts a file for storage on the disk. Can be used for any personal information, or attachments received.
    public func encryptLocalFile(_ data: Data) throws -> AES.GCM.SealedBox {
        try AES.GCM.seal(data, using: databaseEncryptionKey)
    }
    
    /// Decrypts a file that was encrypted with `encryptLocalFile`
    public func decryptLocalFile(_ box: AES.GCM.SealedBox) throws -> Data {
        try AES.GCM.open(box, using: databaseEncryptionKey)
    }
    
    /// Signs a message using this device's Private Key, allowing another client to verify the message's origin.
    @CryptoActor public func sign<T: Codable>(_ value: T) async throws -> Signed<T> {
        try state.sign(value)
    }
    
    @CryptoActor func _signRatchetMessage(_ message: RatchetMessage, rekey: RekeyState) throws -> RatchetedCypherMessage {
        return try RatchetedCypherMessage(
            message: message,
            signWith: state.config.deviceKeys.identity,
            rekey: rekey == .rekey
        )
    }
    
    @CryptoActor internal func _formSharedSecret(with publicKey: PublicKey) throws -> SharedSecret {
        try state.config.deviceKeys.privateKey.sharedSecretFromKeyAgreement(
            with: publicKey
        )
    }
    
    @CryptoActor fileprivate func _deriveSymmetricKey(from secret: SharedSecret, initiator: Username) -> SymmetricKey {
        let salt = Data(
            SHA512.hash(
                data: initiator.raw.lowercased().data(using: .utf8)!
            )
        )
        
        return secret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: salt,
            sharedInfo: "X3DHTemporaryReplacement".data(using: .ascii)!,
            outputByteCount: 32
        )
    }
    
    /// Reads the custom configuration file stored on this device
    public func readCustomConfig() async throws -> Document {
        return await state.config.custom
    }
    
    /// Writes a new custom configuration file to this device
    public func writeCustomConfig(_ custom: Document) async throws {
        try await state.writeCustomConfig(custom)
        await eventHandler.onCustomConfigChange()
    }
    
    func _writeWithRatchetEngine<T>(
        ofUser username: Username,
        deviceId: DeviceId,
        run: @escaping (inout DoubleRatchetHKDF<SHA512>, RekeyState) async throws -> T
    ) async throws -> T {
        let device = try await self._fetchDeviceIdentity(for: username, deviceId: deviceId)
        return try await device._writeWithRatchetEngine(messenger: self, run: run)
    }
    
    @CypherTextKitActor public func p2pTransportDiscovered(_ connection: P2PTransportClient, remotePeer: Peer) async throws {
        connection.delegate = self
        try await state.registerSession(
            P2PSession(
                peer: remotePeer,
                transport: connection,
                client: P2PClient(
                    client: connection,
                    messenger: self,
                    closeInactiveAfter: self.inactiveP2PSessionsTimeout
                )
            )
        )
    }
    
    // TODO: Make internal
    /// An internal implementation that allows CypherMessenger to respond to information received by a P2PConnection
    public func p2pConnectionClosed(_ connection: P2PTransportClient) async throws {
        debugLog("P2P session disconnecting")
        
        return await state.closeP2PConnection(connection)
    }
    
    @CryptoActor internal func _processP2PMessage(
        _ message: SingleCypherMessage,
        remoteMessageId: String,
        sender device: _DecryptedModel<DeviceIdentityModel>
    ) async throws {
        guard let sentDate = message.sentDate, abs(sentDate.timeIntervalSinceNow) <= 60 else {
            // Ignore older P2P messages
            return
        }
        
        var subType = message.messageSubtype ?? ""
        
        assert(subType.hasPrefix("_/p2p/0/"))
        
        subType.removeFirst("_/p2p/0/".count)
        
        var components = subType.split(separator: "/")
        
        guard !components.isEmpty else {
            throw CypherSDKError.badInput
        }
        
        let transportId = String(components.removeFirst())
        
        guard let factory = p2pFactories.first(
            where: { $0.transportLayerIdentifier == transportId }
        ) else {
            throw CypherSDKError.unsupportedTransport
        }
        
        let handle = P2PTransportFactoryHandle(
            transportLayerIdentifier: transportId,
            messenger: self,
            targetConversation: message.target,
            state: P2PFrameworkState(
                remote: Peer(
                    username: device.username,
                    deviceConfig: UserDeviceConfig(
                        deviceId: device.deviceId,
                        identity: device.identity,
                        publicKey: device.publicKey,
                        isMasterDevice: device.isMasterDevice
                    )
                ),
                isMeshEnabled: factory.isMeshEnabled
            )
        )
        
        let client = try? await factory.receiveMessage(message.text, metadata: message.metadata, handle: handle)
        // TODO: What is a P2P session already exists?
        if let client = client {
            client.delegate = self
            try await state.registerSession(
                P2PSession(
                    deviceIdentity: device,
                    transport: client,
                    client: P2PClient(
                        client: client,
                        messenger: self,
                        closeInactiveAfter: self.inactiveP2PSessionsTimeout
                    )
                )
            )
        }
    }
    
    // TODO: Make internal
    /// An internal implementation that allows CypherMessenger to respond to information received by a P2PConnection
    public func p2pConnection(
        _ connection: P2PTransportClient,
        receivedMessage buffer: ByteBuffer
    ) async throws {
        guard buffer.readableBytes <= 16_000_000 else {
            // Package too large for P2P Transport
            return
        }
        
        guard let session = await state.p2pSessions.first(where: {
            $0.transport === connection
        }) else {
            return
        }
        
        return try await session.client.receiveBuffer(buffer)
    }
    
    /// Lists all active P2P connections
    /// Especially useful for when a client wants to purge unneeded sessions
    @CypherTextKitActor public func listOpenP2PConnections() -> [P2PClient] {
        state.p2pSessions.map(\.client)
    }
    
    @CypherTextKitActor public func hasP2PConnection(with username: Username) -> Bool {
        state.p2pSessions.contains { $0.username == username }
    }
    
    internal func getEstablishedP2PConnection(
        with username: Username,
        deviceId: DeviceId
    ) async throws -> P2PClient? {
        await state.p2pSessions.first(where: { user in
            user.username == username && user.deviceId == deviceId
        })?.client
    }
    
    @CryptoActor internal func getEstablishedP2PConnection(
        with device: _DecryptedModel<DeviceIdentityModel>
    ) async throws -> P2PClient? {
        state.p2pSessions.first(where: { user in
            user.username == device.username && user.deviceId == device.deviceId
        })?.client
    }
    
    @CryptoActor internal func createP2PConnection(
        with device: _DecryptedModel<DeviceIdentityModel>,
        targetConversation: TargetConversation,
        preferredTransportIdentifier: String? = nil
    ) async throws {
        if state.p2pSessions.contains(where: { user in
            user.username == device.username && user.deviceId == device.deviceId
        }) {
            return
        }
        
        let transportFactory: P2PTransportClientFactory
        
        if let preferredTransportIdentifier = preferredTransportIdentifier {
            guard let defaultTransport = self.p2pFactories.first(where: {
                $0.transportLayerIdentifier == preferredTransportIdentifier
            }) else {
                throw CypherSDKError.invalidTransport
            }
            
            transportFactory = defaultTransport
        } else {
            guard let factory = self.p2pFactories.first else {
                throw CypherSDKError.invalidTransport
            }
            
            transportFactory = factory
        }
        
        let state = P2PFrameworkState(
            remote: Peer(
                username: device.username,
                deviceConfig: UserDeviceConfig(
                    deviceId: device.deviceId,
                    identity: device.identity,
                    publicKey: device.publicKey,
                    isMasterDevice: device.isMasterDevice
                )
            ),
            isMeshEnabled: transportFactory.isMeshEnabled
        )
        
        let client = try await transportFactory.createConnection(
            handle: P2PTransportFactoryHandle(
                transportLayerIdentifier: transportFactory.transportLayerIdentifier,
                messenger: self,
                targetConversation: targetConversation,
                state: state
            )
        )
        
        // TODO: What if a P2P session already exists?
        if let client = client {
            client.delegate = self
            try await self.state.registerSession(
                P2PSession(
                    deviceIdentity: device,
                    transport: client,
                    client: P2PClient(
                        client: client,
                        messenger: self,
                        closeInactiveAfter: self.inactiveP2PSessionsTimeout
                    )
                )
            )
        }
    }
    
    @CypherTextKitActor public var registeryMode: DeviceRegisteryMode {
        self.state.config.registeryMode
    }
    
    @CypherTextKitActor public func listDevices() async throws -> [UserDevice] {
        return try await self._fetchDeviceIdentities(for: self.username).map { device in
            UserDevice(device: device)
        }
    }
    
    public func renameCurrentDevice(to name: String) async throws {
        let chat = try await getInternalConversation()
        try await chat.sendMagicPacket(
            messageSubtype: "_/devices/rename",
            text: "",
            metadata: BSONEncoder().encode(MagicPackets.RenameDevice(deviceId: self.deviceId, name: name))
        )
    }
}

extension Contact {
    @CypherTextKitActor public func listDevices() async throws -> [UserDevice] {
        return try await messenger._fetchDeviceIdentities(for: username).map { device in
            UserDevice(device: device)
        }
    }
}

extension _DecryptedModel where M == DeviceIdentityModel {
    @CryptoActor func _readWithRatchetEngine(
        message: RatchetedCypherMessage,
        messenger: CypherMessenger
    ) async throws -> Data {
        @CryptoActor func rekey() async throws {
            debugLog("Rekeying - removing ratchet state")
            try self.updateDoubleRatchetState(to: nil)
            try self.setProp(at: \.lastRekey, to: Date())
            
            try await messenger.eventHandler.onRekey(
                withUser: username,
                deviceId: deviceId,
                messenger: messenger
            )
            try await messenger.cachedStore.updateDeviceIdentity(encrypted)
            try await messenger._queueTask(
                .sendMessage(
                    SendMessageTask(
                        message: CypherMessage(
                            message: SingleCypherMessage(
                                messageType: .magic,
                                messageSubtype: "_/ignore",
                                text: "",
                                metadata: [:],
                                order: 0,
                                target: .otherUser(username)
                            )
                        ),
                        recipient: username,
                        recipientDeviceId: deviceId,
                        localId: UUID(),
                        pushType: .none,
                        messageId: UUID().uuidString
                    )
                )
            )
        }
        
        let data: Data
        var ratchet: DoubleRatchetHKDF<SHA512>
        if let existingState = self.doubleRatchet, !message.rekey {
            ratchet = DoubleRatchetHKDF(
                state: existingState,
                configuration: doubleRatchetConfig
            )
            
            do {
                let ratchetMessage = try message.readAndValidate(usingIdentity: self.identity)
                data = try ratchet.ratchetDecrypt(ratchetMessage)
            } catch {
                try await rekey()
                debugLog("Failed to read message", error)
                throw error
            }
        } else {
            guard message.rekey else {
                debugLog("Couldn't read message not marked as rekey")
                throw CypherSDKError.invalidHandshake
            }
            
            do {
                let secret = try messenger._formSharedSecret(with: self.publicKey)
                let symmetricKey = messenger._deriveSymmetricKey(
                    from: secret,
                    initiator: messenger.username
                )
                let ratchetMessage = try message.readAndValidate(usingIdentity: self.identity)
                (ratchet, data) = try DoubleRatchetHKDF.initializeRecipient(
                    secretKey: symmetricKey,
                    localPrivateKey: messenger.state.config.deviceKeys.privateKey,
                    configuration: doubleRatchetConfig,
                    initialMessage: ratchetMessage
                )
            } catch {
                // TODO: Ignore incoming follow-up messages
                debugLog("Failed to initialise recipient", error)
                try await rekey()
                throw error
            }
        }
        
        try self.updateDoubleRatchetState(to: ratchet.state)
        
        try await messenger.cachedStore.updateDeviceIdentity(encrypted)
        return data
    }
    
    @CryptoActor func _writeWithRatchetEngine<T>(
        messenger: CypherMessenger,
        run: @escaping (inout DoubleRatchetHKDF<SHA512>, RekeyState) async throws -> T
    ) async throws -> T {
        var ratchet: DoubleRatchetHKDF<SHA512>
        let rekey: Bool
        
        if let existingState = self.doubleRatchet {
            ratchet = DoubleRatchetHKDF(
                state: existingState,
                configuration: doubleRatchetConfig
            )
            rekey = false
        } else {
            let secret = try messenger._formSharedSecret(with: publicKey)
            let symmetricKey = messenger._deriveSymmetricKey(from: secret, initiator: self.username)
            try self.setProp(at: \.lastRekey, to: Date())
            ratchet = try DoubleRatchetHKDF.initializeSender(
                secretKey: symmetricKey,
                contactingRemote: publicKey,
                configuration: doubleRatchetConfig
            )
            rekey = true
        }
        
        let result = try await run(&ratchet, rekey ? .rekey : .next)
        try updateDoubleRatchetState(to: ratchet.state)
        
        try await messenger.cachedStore.updateDeviceIdentity(encrypted)
        return result
    }
}

fileprivate struct BSONRatchetHeaderEncoder: RatchetHeaderEncoder {
    init() {}
    
    func encodeRatchetHeader(_ header: RatchetMessage.Header) throws -> Data {
        try BSONEncoder().encode(header).makeData()
    }
    
    func decodeRatchetHeader(from data: Data) throws -> RatchetMessage.Header {
        try BSONDecoder().decode(RatchetMessage.Header.self, from: Document(data: data))
    }
    
    func concatenate(authenticatedData: Data, withHeader header: Data) -> Data {
        let info = header + authenticatedData
        let digest = SHA256.hash(data: info)
        return digest.withUnsafeBytes { buffer in
            Data(buffer: buffer.bindMemory(to: UInt8.self))
        }
    }
}

fileprivate let doubleRatchetConfig = DoubleRatchetConfiguration<SHA512>(
    info: "Cypher Protocol".data(using: .ascii)!,
    symmetricEncryption: ChaChaPolyEncryption(),
    kdf: DefaultRatchetKDF<SHA256>(
        messageKeyConstant: Data([0x00]),
        chainKeyConstant: Data([0x01]),
        sharedInfo: Data([0x02, 0x03])
    ),
    headerEncoder: BSONRatchetHeaderEncoder(),
    headerAssociatedDataGenerator: .constant("Cypher ChatMessage".data(using: .ascii)!),
    maxSkippedMessageKeys: 100
)

public struct UserDevice: Identifiable {
    public var id: DeviceId { config.deviceId }
    public let username: Username
    public let config: UserDeviceConfig
    public let name: String?
    
    @CypherTextKitActor internal init(device: _DecryptedModel<DeviceIdentityModel>) {
        self.username = device.username
        self.name = device.deviceName
        self.config = UserDeviceConfig(
            deviceId: device.deviceId,
            identity: device.identity,
            publicKey: device.publicKey,
            isMasterDevice: device.isMasterDevice
        )
    }
}

enum MagicPackets {
    internal struct RenameDevice: Codable {
        let deviceId: DeviceId
        let name: String
    }
}
