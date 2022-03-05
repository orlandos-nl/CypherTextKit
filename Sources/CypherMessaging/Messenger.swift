import BSON
import Foundation
import Crypto
import NIO
import CypherProtocol

public enum DeviceRegisteryMode: Int, Codable {
    case masterDevice, childDevice, unregistered
}

@globalActor public final actor CypherTextKitActor {
    public static let shared = CypherTextKitActor()
    
    private init() {}
}

public typealias CryptoActor = CypherTextKitActor

internal struct _CypherMessengerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case databaseEncryptionKey = "a"
        case deviceKeys = "b"
        case username = "c"
        case registeryMode = "d"
        case custom = "e"
        case deviceIdentityId = "f"
    }
    
    let databaseEncryptionKey: Data
    let deviceKeys: DevicePrivateKeys
    let username: Username
    var registeryMode: DeviceRegisteryMode
    var custom: Document
    let deviceIdentityId: Int
}

enum RekeyState {
    case rekey, next
}

/// Provided by CypherMessenger to a factory (function) so that it can create a Transport Client to the app's servers
public struct TransportCreationRequest {
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
        deviceIdentity: DecryptedModel<DeviceIdentityModel>,
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
fileprivate final actor CypherMessengerActor {
    var config: _CypherMessengerConfig
    var p2pSessions = [P2PSession]()
    var appPassword: String
    let cachedStore: _CypherMessengerStoreCache
    
    internal init(config: _CypherMessengerConfig, cachedStore: _CypherMessengerStoreCache, appPassword: String) {
        self.config = config
        self.p2pSessions = []
        self.appPassword = appPassword
        self.cachedStore = cachedStore
    }
    
    func updateConfig(_ run: @Sendable (inout _CypherMessengerConfig) -> ()) async throws {
        let salt = try await self.cachedStore.readLocalDeviceSalt()
        let appEncryptionKey = CypherMessenger.formAppEncryptionKey(appPassword: appPassword, salt: salt)
        run(&config)
        let encryptedConfig = try Encrypted(config, encryptionKey: appEncryptionKey)
        try await self.cachedStore.writeLocalDeviceConfig(encryptedConfig.makeData())
    }
    
    func changeAppPassword(to appPassword: String) async throws {
        let salt = try await self.cachedStore.readLocalDeviceSalt()
        let appEncryptionKey = CypherMessenger.formAppEncryptionKey(appPassword: appPassword, salt: salt)
        
        let encryptedConfig = try Encrypted(self.config, encryptionKey: appEncryptionKey)
        let data = try BSONEncoder().encode(encryptedConfig).makeData()
        try await self.cachedStore.writeLocalDeviceConfig(data)
        self.appPassword = appPassword
    }
    
    var isSetupCompleted: Bool {
        switch config.registeryMode {
        case .unregistered:
            return false
        case .childDevice, .masterDevice:
            return true
        }
    }
    
    public func sign<T: Codable>(_ value: T) throws -> Signed<T> {
        try Signed(value, signedBy: config.deviceKeys.identity)
    }
    
    public func writeCustomConfig(_ custom: Document) async throws {
        let salt = try await self.cachedStore.readLocalDeviceSalt()
        let appEncryptionKey = CypherMessenger.formAppEncryptionKey(appPassword: self.appPassword, salt: salt)
        var newConfig = self.config
        newConfig.custom = custom
        let encryptedConfig = try Encrypted(newConfig, encryptionKey: appEncryptionKey)
        try await self.cachedStore.writeLocalDeviceConfig(encryptedConfig.makeData())
        self.config = newConfig
    }
    
    func closeP2PConnection(_ connection: P2PTransportClient) async {
        debugLog("Removing P2P session from active pool")
        guard let index = p2pSessions.firstIndex(where: {
            $0.transport === connection
        }) else {
            return
        }
        
        let session = p2pSessions.remove(at: index)
        return await session.client.disconnect()
    }
    
    func registerSession(_ session: P2PSession) {
        p2pSessions.append(session)
    }
}

/// A CypherMessenger is the heart of CypherTextKit Framework, similar to an "Application" class.
/// CypherMessenger is responsible for orchestrating end-to-end encrypted communication of any kind.
///
/// CypherMessenger can be created as a singleton, but multiple clients in the same process is supported.
@available(macOS 10.15, iOS 13, *)
public final class CypherMessenger: CypherTransportClientDelegate, P2PTransportClientDelegate {
    internal let eventLoop: EventLoop
    private(set) var jobQueue: JobQueue!
    private var inactiveP2PSessionsTimeout: Int? = 30
    internal let deviceIdentityId: Int
    fileprivate let state: CypherMessengerActor
    let p2pFactories: [P2PTransportClientFactory]
    internal let eventHandler: CypherMessengerEventHandler
    internal let cachedStore: _CypherMessengerStoreCache
    internal let databaseEncryptionKey: SymmetricKey
    
    /// The TransportClient implementation provided to CypherTextKit for this CypherMessenger to communicate through
    public let transport: CypherServerTransportClient
    
    public var authenticated: AuthenticationState { transport.authenticated }
    
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
        
        let config = _CypherMessengerConfig(
            databaseEncryptionKey: databaseEncryptionKeyData,
            deviceKeys: DevicePrivateKeys(deviceId: deviceId),
            username: username,
            registeryMode: .unregistered,
            custom: [:],
            deviceIdentityId: .random(in: 1 ..< .max)
        )
        
        let salt = try await database.readLocalDeviceSalt()
        let appEncryptionKey = Self.formAppEncryptionKey(
            appPassword: appPassword,
            salt: salt
        )
        
        let userConfig = try UserConfig(
            mainDevice: config.deviceKeys,
            otherDevices: []
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
            var config = config
            config.registeryMode = .masterDevice
            encryptedConfig = try Encrypted(config, encryptionKey: appEncryptionKey)
            
            try await database.writeLocalDeviceConfig(encryptedConfig.makeData())
            try await transport.publishKeyBundle(userConfig)
            
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
        let config = try await encryptedConfig.decrypt(using: encryptionKey)
        let transportRequest = try TransportCreationRequest(
            username: config.username,
            deviceId: config.deviceKeys.deviceId,
            userConfig: UserConfig(mainDevice: config.deviceKeys, otherDevices: []),
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
            _ = try await config.decrypt(using: appEncryptionKey)
            return true
        } catch {
            return false
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
        if try await isRegisteredOnline() {
            try await updateConfig { config in
                config.registeryMode = .childDevice
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
    
    // TODO: Make internal
    /// Internal API that CypherMessenger uses to read information from Transport Clients
    public func receiveServerEvent(_ event: CypherServerEvent) async throws {
        switch event.raw {
        case let .multiRecipientMessageSent(message, id: messageId, byUser: sender, deviceId: deviceId):
            //            guard let key = message.keys.first(where: {
            //                $0.user == self.config.username && $0.deviceId == self.config.deviceKeys.deviceId
            //            }) else {
            //                return
            //            }
            
            return try await self.jobQueue.queueTask(
                CypherTask.processMultiRecipientMessage(
                    ReceiveMultiRecipientMessageTask(
                        message: message,
                        messageId: messageId,
                        sender: sender,
                        deviceId: deviceId
                    )
                )
            )
        case let .messageSent(message, id: messageId, byUser: sender, deviceId: deviceId):
            return try await self.jobQueue.queueTask(
                CypherTask.processMessage(
                    ReceiveMessageTask(
                        message: message,
                        messageId: messageId,
                        sender: sender,
                        deviceId: deviceId
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
    public func addDevice(_ deviceConfig: UserDeviceConfig) async throws {
        var config = try await transport.readKeyBundle(forUsername: self.username)
        guard await config.identity.data == state.config.deviceKeys.identity.publicKey.data else {
            throw CypherSDKError.corruptUserConfig
        }
        
        try config.addDeviceConfig(deviceConfig, signedWith: await state.config.deviceKeys.identity)
        try await self.transport.publishKeyBundle(config)
        let internalConversation = try await self.getInternalConversation()
        let metadata = try BSONEncoder().encode(deviceConfig)
        _ = try await self._createDeviceIdentity(
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
        
        for contact in try await self.listContacts() {
            try await _writeMessage(message, to: contact.username)
        }
        
        try await eventHandler.onDeviceRegistery(deviceConfig.deviceId, messenger: self)
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
    
    func _withCreatedMultiRecipientMessage<T>(
        encrypting message: CypherMessage,
        forDevices devices: [DecryptedModel<DeviceIdentityModel>],
        run: @Sendable (MultiRecipientCypherMessage) async throws -> T
    ) async throws -> T {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
        
        let messageData = try BSONEncoder().encode(message).makeData()
        let encryptedMessage = try AES.GCM.seal(messageData, using: key).combined!
        
        var keyMessages = [MultiRecipientCypherMessage.ContainerKey]()
        var rekeyDevices = [DecryptedModel<DeviceIdentityModel>]()
        
        for device in devices {
            let keyMessage = try await device._writeWithRatchetEngine(messenger: self) { ratchetEngine, rekeyState -> MultiRecipientCypherMessage.ContainerKey in
                let ratchetMessage = try ratchetEngine.ratchetEncrypt(keyData)
                
                return try await MultiRecipientCypherMessage.ContainerKey(
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
                signWith: await state.config.deviceKeys.identity,
                keys: keyMessages
            )
            
            return try await run(message)
        } catch {
            for device in rekeyDevices {
                // Device was instantiated with a rekey, but the message wasn't sent
                // So to prevent any further confusion & issues, just reset this
                try await device.updateDoubleRatchetState(to: nil)
            }
            
            throw error
        }
    }
    
    @CryptoActor final class ModelCache {
        private var cache = [UUID: Weak<AnyObject>]()
        @CryptoActor func getModel<M: Model>(ofType: M.Type, forId id: UUID) -> DecryptedModel<M>? {
            cache[id]?.object as? DecryptedModel<M>
        }
        
        @CryptoActor func addModel<M: Model>(_ model: DecryptedModel<M>, forId id: UUID) {
            cache[id] = Weak(object: model)
        }
    }
    
    @CryptoActor private let cache = ModelCache()
    
    /// Decrypts a model as provided by the database
    /// It is critical to call this method for decryption for stability reasons, as CypherMessenger prevents duplicate representations of a Model from existing at the same time.
    @CryptoActor public func decrypt<M: Model>(_ model: M) throws -> DecryptedModel<M> {
        if let decrypted = cache.getModel(ofType: M.self, forId: model.id) {
            return decrypted
        }
        
        let decrypted = try DecryptedModel(model: model, encryptionKey: databaseEncryptionKey)
        cache.addModel(decrypted, forId: model.id)
        return decrypted
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
        try await state.sign(value)
    }
    
    @CryptoActor func _signRatchetMessage(_ message: RatchetMessage, rekey: RekeyState) async throws -> RatchetedCypherMessage {
        return try RatchetedCypherMessage(
            message: message,
            signWith: await state.config.deviceKeys.identity,
            rekey: rekey == .rekey
        )
    }
    
    @CryptoActor fileprivate func _formSharedSecret(with publicKey: PublicKey) async throws -> SharedSecret {
        try await state.config.deviceKeys.privateKey.sharedSecretFromKeyAgreement(
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
    }
    
    func _writeWithRatchetEngine<T>(
        ofUser username: Username,
        deviceId: DeviceId,
        run: @escaping (inout DoubleRatchetHKDF<SHA512>, RekeyState) async throws -> T
    ) async throws -> T {
        let device = try await self._fetchDeviceIdentity(for: username, deviceId: deviceId)
        return try await device._writeWithRatchetEngine(messenger: self, run: run)
    }
    
    // TODO: Make internal
    /// An internal implementation that allows CypherMessenger to respond to information received by a P2PConnection
    public func p2pConnection(
        _ connection: P2PTransportClient,
        closedWithOptions: Set<P2PTransportClosureOption>
    ) async throws {
        debugLog("P2P session disconnecting")
        
        if closedWithOptions.contains(.reconnnectPossible) {
            do {
                return try await connection.reconnect()
            } catch {
                debugLog("Reconnecting P2P connection failed")
                return await state.closeP2PConnection(connection)
            }
        }
        
        return await state.closeP2PConnection(connection)
    }
    
    @CryptoActor internal func _processP2PMessage(
        _ message: SingleCypherMessage,
        remoteMessageId: String,
        sender device: DecryptedModel<DeviceIdentityModel>
    ) async throws {
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
                username: device.username,
                deviceId: device.deviceId,
                identity: device.identity
            )
        )
        
        let client = try? await factory.receiveMessage(message.text, metadata: message.metadata, handle: handle)
        // TODO: What is a P2P session already exists?
        if let client = client {
            client.delegate = self
            await state.registerSession(
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
        guard let session = await state.p2pSessions.first(where: {
            $0.transport === connection
        }) else {
            return
        }
        
        return try await session.client.receiveBuffer(buffer)
    }
    
    /// Lists all active P2P connections
    /// Especially useful for when a client wants to purge unneeded sessions
    public func listOpenP2PConnections() async -> [P2PClient] {
        await state.p2pSessions.map(\.client)
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
        with device: DecryptedModel<DeviceIdentityModel>
    ) async throws -> P2PClient? {
        await state.p2pSessions.first(where: { user in
            user.username == device.username && user.deviceId == device.deviceId
        })?.client
    }
    
    @CryptoActor internal func createP2PConnection(
        with device: DecryptedModel<DeviceIdentityModel>,
        targetConversation: TargetConversation,
        preferredTransportIdentifier: String? = nil
    ) async throws {
        if await state.p2pSessions.contains(where: { user in
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
            username: device.username,
            deviceId: device.deviceId,
            identity: device.identity
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
            await self.state.registerSession(
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
}

extension DecryptedModel where M == DeviceIdentityModel {
    @CryptoActor func _readWithRatchetEngine(
        ofUser username: Username,
        deviceId: DeviceId,
        message: RatchetedCypherMessage,
        messenger: CypherMessenger
    ) async throws -> Data {
        func rekey() async throws {
            debugLog("Rekeying - removing ratchet state")
            try await self.updateDoubleRatchetState(to: nil)
            
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
                let secret = try await messenger._formSharedSecret(with: self.publicKey)
                let symmetricKey = messenger._deriveSymmetricKey(
                    from: secret,
                    initiator: messenger.username
                )
                let ratchetMessage = try message.readAndValidate(usingIdentity: self.identity)
                (ratchet, data) = try DoubleRatchetHKDF.initializeRecipient(
                    secretKey: symmetricKey,
                    localPrivateKey: await messenger.state.config.deviceKeys.privateKey,
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
        
        try await self.updateDoubleRatchetState(to: ratchet.state)
        
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
            let secret = try await messenger._formSharedSecret(with: publicKey)
            let symmetricKey = messenger._deriveSymmetricKey(from: secret, initiator: self.username)
            ratchet = try DoubleRatchetHKDF.initializeSender(
                secretKey: symmetricKey,
                contactingRemote: publicKey,
                configuration: doubleRatchetConfig
            )
            rekey = true
        }
        
        let result = try await run(&ratchet, rekey ? .rekey : .next)
        try await updateDoubleRatchetState(to: ratchet.state)
        
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
