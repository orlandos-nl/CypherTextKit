import BSON
import Foundation
import Crypto
import NIO
import CypherProtocol

public enum DeviceRegisteryMode: Int, Codable {
    case masterDevice, childDevice, unregistered
}

fileprivate struct _CypherMessengerConfig: Codable {
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

public struct TransportCreationRequest {
    public let username: Username
    public let deviceId: DeviceId
    public let userConfig: UserConfig
    internal let signingIdentity: PrivateSigningKey
    public var identity: PublicSigningKey { signingIdentity.publicKey }
    
    public func signature<D: DataProtocol>(for data: D) throws -> Data {
        try signingIdentity.signature(for: data)
    }
}

internal struct P2PSession {
    let username: Username
    let deviceId: DeviceId
    let publicKey: PublicKey
    let identity: PublicSigningKey
    let transport: P2PTransportClient
    let client: P2PClient
    
    init(
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

public final class CypherMessenger: CypherTransportClientDelegate, P2PTransportClientDelegate {
    public let eventLoop: EventLoop
    private(set) var jobQueue: JobQueue!
    private let appPassword: String
    private var config: _CypherMessengerConfig
    private var p2pFactories = [P2PTransportClientFactory]()
    private var p2pSessions = [P2PSession]()
    private var inactiveP2PSessionsTimeout: Int? = 30
    internal var deviceIdentityId: Int { config.deviceIdentityId }
    internal let eventHandler: CypherMessengerEventHandler
    internal let cachedStore: _CypherMessengerStoreCache
    internal let transport: CypherServerTransportClient
    internal let databaseEncryptionKey: SymmetricKey
    
    public var authenticated: AuthenticationState { transport.authenticated }
    public var username: Username { config.username }
    public var deviceId: DeviceId { config.deviceKeys.deviceId }
    
    private init(
        eventLoop: EventLoop,
        appPassword: String,
        eventHandler: CypherMessengerEventHandler,
        config: _CypherMessengerConfig,
        database: CypherMessengerStore,
        p2pFactories: [P2PTransportClientFactory],
        transport: CypherServerTransportClient
    ) {
        self.eventLoop = eventLoop
        self.eventHandler = eventHandler
        self.config = config
        self.cachedStore = _CypherMessengerStoreCache(base: database, eventLoop: eventLoop)
        self.transport = transport
        self.databaseEncryptionKey = SymmetricKey(data: config.databaseEncryptionKey)
        self.p2pFactories = p2pFactories
        self.appPassword = appPassword
        self.transport.delegate = self
        self.jobQueue = JobQueue(messenger: self, database: self.cachedStore, databaseEncryptionKey: self.databaseEncryptionKey)
        
        self.transport.reconnect().whenSuccess(jobQueue.resume)
    }
    
    public static func registerMessenger<
        Transport: CypherServerTransportClient
    >(
        username: Username,
        appPassword: String,
        usingTransport createTransport: @escaping (TransportCreationRequest) -> EventLoopFuture<Transport>,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler,
        on eventLoop: EventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    ) -> EventLoopFuture<CypherMessenger> {
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
        
        return database.readLocalDeviceSalt().map { salt -> SymmetricKey in
            Self.formAppEncryptionKey(
                appPassword: appPassword,
                salt: salt
            )
        }.flatMap { appEncryptionKey -> EventLoopFuture<CypherMessenger> in
            let userConfig: UserConfig
            let encryptedConfig: Encrypted<_CypherMessengerConfig>
            
            do {
                userConfig = try UserConfig(
                    mainDevice: config.deviceKeys,
                    otherDevices: []
                )
                
                encryptedConfig = try Encrypted(config, encryptionKey: appEncryptionKey)
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
            
            let transportRequest = TransportCreationRequest(
                username: username,
                deviceId: deviceId,
                userConfig: userConfig,
                signingIdentity: config.deviceKeys.identity
            )
            
            return createTransport(transportRequest).flatMap { transport -> EventLoopFuture<CypherMessenger> in
                transport.readKeyBundle(forUsername: username).flatMap { existingKeys -> EventLoopFuture<CypherMessenger> in
                    // Existing config found, this is a new device that needs to be registered
                    let messenger = CypherMessenger(
                        eventLoop: eventLoop,
                        appPassword: appPassword,
                        eventHandler: eventHandler,
                        config: config,
                        database: database,
                        p2pFactories: p2pFactories,
                        transport: transport
                    )
                    
                    if existingKeys.identity.data == config.deviceKeys.identity.publicKey.data {
                        return database.writeLocalDeviceConfig(encryptedConfig.makeData()).flatMap {
                            eventLoop.makeSucceededFuture(messenger)
                        }
                    }
                    
                    let metadata = UserDeviceConfig(
                        deviceId: config.deviceKeys.deviceId,
                        identity: config.deviceKeys.identity.publicKey,
                        publicKey: config.deviceKeys.privateKey.publicKey,
                        isMasterDevice: false
                    )
                    
                    return database.writeLocalDeviceConfig(encryptedConfig.makeData()).flatMap {
                        transport.requestDeviceRegistery(metadata)
                    }.map { messenger }
                }.flatMapError { error -> EventLoopFuture<CypherMessenger> in
                    // No config found, register this device as the master
                    var config = config
                    config.registeryMode = .masterDevice
                    
                    return database.writeLocalDeviceConfig(encryptedConfig.makeData()).flatMap {
                        return transport.publishKeyBundle(userConfig)
                    }.map {
                        CypherMessenger(
                            eventLoop: eventLoop,
                            appPassword: appPassword,
                            eventHandler: eventHandler,
                            config: config,
                            database: database,
                            p2pFactories: p2pFactories,
                            transport: transport
                        )
                    }
                }
            }
        }
    }
    
    public static func registerMessenger<
        Transport: ConnectableCypherTransportClient
    >(
        username: Username,
        authenticationMethod: AuthenticationMethod,
        appPassword: String,
        usingTransport: Transport.Type,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler,
        on eventLoop: EventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    ) -> EventLoopFuture<CypherMessenger> {
        Self.registerMessenger(
            username: username,
            appPassword: appPassword,
            usingTransport: { request in
                Transport.login(
                    Credentials(
                        username: username,
                        deviceId: request.deviceId,
                        method: authenticationMethod
                    ),
                    eventLoop: eventLoop
                )
            },
            p2pFactories: p2pFactories,
            database: database,
            eventHandler: eventHandler,
            on: eventLoop
        )
    }
    
    public static func resumeMessenger<
        Transport: ConnectableCypherTransportClient
    >(
        username: Username,
        authenticationMethod: AuthenticationMethod,
        appPassword: String,
        usingTransport createTransport: Transport.Type,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler,
        on eventLoop: EventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    ) -> EventLoopFuture<CypherMessenger> {
        resumeMessenger(
            appPassword: appPassword,
            usingTransport: { request in
                Transport.login(
                    Credentials(
                        username: username,
                        deviceId: request.deviceId,
                        method: authenticationMethod
                    ),
                    eventLoop: eventLoop
                )
            },
            p2pFactories: p2pFactories,
            database: database,
            eventHandler: eventHandler,
            on: eventLoop
        )
    }
    
    public static func resumeMessenger<
        Transport: CypherServerTransportClient
    >(
        appPassword: String,
        usingTransport createTransport: @escaping (TransportCreationRequest) -> EventLoopFuture<Transport>,
        p2pFactories: [P2PTransportClientFactory] = [],
        database: CypherMessengerStore,
        eventHandler: CypherMessengerEventHandler,
        on eventLoop: EventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    ) -> EventLoopFuture<CypherMessenger> {
        return database.readLocalDeviceSalt().flatMap { salt -> EventLoopFuture<_CypherMessengerConfig> in
            let encryptionKey = Self.formAppEncryptionKey(appPassword: appPassword, salt: salt)
            
            return database.readLocalDeviceConfig().flatMapThrowing { data -> _CypherMessengerConfig in
                let box = try AES.GCM.SealedBox(combined: data)
                let config = Encrypted<_CypherMessengerConfig>(representing: box)
                return try config.decrypt(using: encryptionKey)
            }
        }.flatMap { config in
            do {
                let transportRequest = try TransportCreationRequest(
                    username: config.username,
                    deviceId: config.deviceKeys.deviceId,
                    userConfig: UserConfig(mainDevice: config.deviceKeys, otherDevices: []),
                    signingIdentity: config.deviceKeys.identity
                )
                
                return createTransport(transportRequest).map { transport in
                    CypherMessenger(
                        eventLoop: eventLoop,
                        appPassword: appPassword,
                        eventHandler: eventHandler,
                        config: config,
                        database: database,
                        p2pFactories: p2pFactories,
                        transport: transport
                    )
                }
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }
    }
    
    fileprivate static func formAppEncryptionKey(appPassword: String, salt: String) -> SymmetricKey {
        // TODO: PBKDF2
        var key = appPassword
        
        // Force unwrap, because the abcense would weaken the key
        key += salt
        
        // SHA-256 is used, because this will output a correctly sized key
        // SHA-256 is a good algorithm that's widely used and hasn't shown weaknesses to date
        return SymmetricKey(data: SHA256.hash(data: key.data(using: .utf8)!))
    }
    
    public func verifyAppPassword(matches appPassword: String) -> EventLoopFuture<Bool> {
        return self.cachedStore.readLocalDeviceSalt().flatMap { salt -> EventLoopFuture<Bool> in
            let encryptionKey = Self.formAppEncryptionKey(appPassword: appPassword, salt: salt)
            
            return self.cachedStore.readLocalDeviceConfig().map { data -> Bool in
                do {
                    let box = try AES.GCM.SealedBox(combined: data)
                    let config = Encrypted<_CypherMessengerConfig>(representing: box)
                    _ = try config.decrypt(using: encryptionKey)
                    return true
                } catch {
                    return false
                }
            }
        }
    }
    
    public func changeAppPassword(to appPassword: String) -> EventLoopFuture<Void> {
        return self.cachedStore.readLocalDeviceSalt().flatMapThrowing { salt in
            let appEncryptionKey = Self.formAppEncryptionKey(appPassword: appPassword, salt: salt)
            
            let encryptedConfig = try Encrypted(self.config, encryptionKey: appEncryptionKey)
            return try BSONEncoder().encode(encryptedConfig).makeData()
        }.flatMap { data in
            return self.cachedStore.writeLocalDeviceConfig(data)
        }
    }
    
    // TODO: Make internal
    public func receiveServerEvent(_ event: CypherServerEvent) -> EventLoopFuture<Void> {
        switch event.raw {
        case let .multiRecipientMessageSent(message, id: messageId, byUser: sender, deviceId: deviceId):
            //            guard let key = message.keys.first(where: {
            //                $0.user == self.config.username && $0.deviceId == self.config.deviceKeys.deviceId
            //            }) else {
            //                return
            //            }
            
            return self.jobQueue.queueTask(
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
            return self.jobQueue.queueTask(
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
            return self.jobQueue.queueTask(
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
            return self.jobQueue.queueTask(
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
            guard self.config.registeryMode == .masterDevice, !deviceConfig.isMasterDevice else {
                debugLog("Received message intented for master device")
                return eventLoop.makeFailedFuture(CypherSDKError.notMasterDevice)
            }
            
            return eventHandler.onDeviceRegisteryRequest(deviceConfig, messenger: self)
        }
    }
    
    public func emptyCaches() {
        cachedStore.emptyCaches()
    }
    
    public func addDevice(_ deviceConfig: UserDeviceConfig) -> EventLoopFuture<Void> {
        return transport.readKeyBundle(forUsername: self.username).flatMap { config in
            guard config.identity.data == self.config.deviceKeys.identity.publicKey.data else {
                return self.eventLoop.makeFailedFuture(CypherSDKError.corruptUserConfig)
            }
            
            do {
                var config = config
                try config.addDeviceConfig(deviceConfig, signedWith: self.config.deviceKeys.identity)
                return self.transport.publishKeyBundle(config).flatMap { () -> EventLoopFuture<Void> in
                    self.getInternalConversation().flatMap { internalConversation in
                        do {
                            let metadata = try BSONEncoder().encode(deviceConfig)
                            return self._createDeviceIdentity(
                                from: deviceConfig,
                                forUsername: self.username
                            ).flatMap { _ -> EventLoopFuture<Void> in
                                return internalConversation.sendInternalMessage(
                                    SingleCypherMessage(
                                        messageType: .magic,
                                        messageSubtype: "_/devices/announce",
                                        text: deviceConfig.deviceId.raw,
                                        metadata: metadata,
                                        order: 0,
                                        target: .currentUser
                                    )
                                )
                            }
                        } catch {
                            return self.eventLoop.makeFailedFuture(error)
                        }
                    }
                }
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        }
    }
    
    func _createMultiRecipientMessage(
        encrypting message: CypherMessage,
        forDevices devices: [DecryptedModel<DeviceIdentityModel>]
    ) -> EventLoopFuture<MultiRecipientCypherMessage> {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
        
        let encryptedMessage: Data
        
        do {
            let messageData = try BSONEncoder().encode(message).makeData()
            encryptedMessage = try AES.GCM.seal(messageData, using: key).combined!
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
        
        let keyMessages = devices.map { device in
            self._writeWithRatchetEngine(ofDevice: device) { ratchetEngine, rekeyState -> EventLoopFuture<MultiRecipientCypherMessage.ContainerKey> in
                do {
                    let ratchetMessage = try ratchetEngine.ratchetEncrypt(keyData)
                    
                    return try self.eventLoop.makeSucceededFuture(
                        MultiRecipientCypherMessage.ContainerKey(
                            user: device.props.username,
                            deviceId: device.props.deviceId,
                            message: self._signRatchetMessage(
                                ratchetMessage,
                                rekey: rekeyState
                            )
                        )
                    )
                } catch {
                    debugLog("Send message failed", error)
                    return self.eventLoop.makeFailedFuture(error)
                }
            }
        }
        
        return EventLoopFuture.whenAllSucceed(keyMessages, on: eventLoop).flatMapThrowing { keyMessages in
            try MultiRecipientCypherMessage(
                encryptedMessage: encryptedMessage,
                signWith: self.config.deviceKeys.identity,
                keys: keyMessages
            )
        }
    }
    
    public func decrypt<M: Model>(_ model: M) -> DecryptedModel<M> {
        model.decrypted(using: databaseEncryptionKey)
    }
    
    public func encryptLocalFile(_ data: Data) throws -> AES.GCM.SealedBox {
        try AES.GCM.seal(data, using: databaseEncryptionKey)
    }
    
    public func decryptLocalFile(_ box: AES.GCM.SealedBox) throws -> Data {
        try AES.GCM.open(box, using: databaseEncryptionKey)
    }
    
    public func sign<T: Codable>(_ value: T) throws -> Signed<T> {
        try Signed(value, signedBy: config.deviceKeys.identity)
    }
    
    func _signRatchetMessage(_ message: RatchetMessage, rekey: RekeyState) throws -> RatchetedCypherMessage {
        try RatchetedCypherMessage(
            message: message,
            signWith: self.config.deviceKeys.identity,
            rekey: rekey == .rekey
        )
    }
    
    fileprivate func _formSharedSecret(with publicKey: PublicKey) throws -> SharedSecret {
        try config.deviceKeys.privateKey.sharedSecretFromKeyAgreement(
            with: publicKey
        )
    }
    
    fileprivate func _deriveSymmetricKey(from secret: SharedSecret, initiator: Username) -> SymmetricKey {
        let salt = Data(
            SHA256.hash(
                data: initiator.raw.lowercased().data(using: .utf8)!
            )
        )
        
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: "X3DHTemporaryReplacement".data(using: .ascii)!,
            outputByteCount: 32
        )
    }
    
    public func readCustomConfig() -> EventLoopFuture<Document> {
        return eventLoop.makeSucceededFuture(config.custom)
    }
    
    public func writeCustomConfig(_ custom: Document) -> EventLoopFuture<Void> {
        return verifyAppPassword(matches: appPassword).flatMap { matches -> EventLoopFuture<String> in
            guard matches else {
                return self.eventLoop.makeFailedFuture(CypherSDKError.incorrectAppPassword)
            }
            
            return self.cachedStore.readLocalDeviceSalt()
        }.flatMap { salt in
            do {
                let appEncryptionKey = Self.formAppEncryptionKey(appPassword: self.appPassword, salt: salt)
                var newConfig = self.config
                newConfig.custom = custom
                let encryptedConfig = try Encrypted(newConfig, encryptionKey: appEncryptionKey)
                return self.cachedStore.writeLocalDeviceConfig(try BSONEncoder().encode(encryptedConfig).makeData()).map {
                    self.config = newConfig
                }
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        }
    }
    
    private func _writeWithRatchetEngine<T>(
        ofDevice device: DecryptedModel<DeviceIdentityModel>,
        run: @escaping (inout DoubleRatchetHKDF<SHA512>, RekeyState) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        var ratchet: DoubleRatchetHKDF<SHA512>
        let rekey: Bool
        
        if let existingState = device.doubleRatchet {
            ratchet = DoubleRatchetHKDF(
                state: existingState,
                configuration: doubleRatchetConfig
            )
            rekey = false
        } else {
            do {
                let secret = try self._formSharedSecret(with: device.props.publicKey)
                let symmetricKey = self._deriveSymmetricKey(from: secret, initiator: self.username)
                ratchet = try DoubleRatchetHKDF.initializeSender(
                    secretKey: symmetricKey,
                    contactingRemote: device.props.publicKey,
                    configuration: doubleRatchetConfig
                )
                rekey = true
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        }
        
        let result = run(&ratchet, rekey ? .rekey : .next)
        device.doubleRatchet = ratchet.state
        
        return self.cachedStore.updateDeviceIdentity(device.encrypted).flatMap {
            result
        }
    }
    
    func _writeWithRatchetEngine<T>(
        ofUser username: Username,
        deviceId: DeviceId,
        run: @escaping (inout DoubleRatchetHKDF<SHA512>, RekeyState) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        self._fetchDeviceIdentity(for: username, deviceId: deviceId).flatMap { device in
            self._writeWithRatchetEngine(ofDevice: device, run: run)
        }
    }
    
    func _readWithRatchetEngine(
        ofUser username: Username,
        deviceId: DeviceId,
        message: RatchetedCypherMessage
    ) -> EventLoopFuture<(Data, DecryptedModel<DeviceIdentityModel>)> {
        self._fetchDeviceIdentity(for: username, deviceId: deviceId).flatMap { device in
            func rekey() -> EventLoopFuture<Void> {
                device.doubleRatchet = nil
                
                return self.eventHandler.onRekey(
                    withUser: username,
                    deviceId: deviceId,
                    messenger: self
                ).flatMap {
                    self.cachedStore.updateDeviceIdentity(device.encrypted)
                }.flatMap {
                    self._queueTask(
                        .sendMessage(
                            SendMessageTask(
                                message: CypherMessage(
                                    message: SingleCypherMessage(
                                        messageType: .magic,
                                        messageSubtype: "_/protocol/rekey",
                                        text: "",
                                        metadata: [:],
                                        order: 0,
                                        target: .otherUser(username)
                                    )
                                ),
                                recipient: username,
                                recipientDeviceId: deviceId,
                                localId: UUID(),
                                messageId: UUID().uuidString
                            )
                        )
                    )
                }
            }
            
            let data: Data
            var ratchet: DoubleRatchetHKDF<SHA512>
            if let existingState = device.doubleRatchet, !message.rekey {
                ratchet = DoubleRatchetHKDF(
                    state: existingState,
                    configuration: doubleRatchetConfig
                )
                
                do {
                    let ratchetMessage = try message.readAndValidate(usingIdentity: device.props.identity)
                    data = try ratchet.ratchetDecrypt(ratchetMessage)
                } catch {
                    return rekey().flatMapThrowing {
                        throw error
                    }
                }
            } else {
                guard message.rekey else {
                    return rekey().flatMapThrowing {
                        throw CypherSDKError.invalidHandshake
                    }
                }
                
                do {
                    let secret = try self._formSharedSecret(with: device.props.publicKey)
                    let symmetricKey = self._deriveSymmetricKey(from: secret, initiator: username)
                    let ratchetMessage = try message.readAndValidate(usingIdentity: device.props.identity)
                    (ratchet, data) = try DoubleRatchetHKDF.initializeRecipient(
                        secretKey: symmetricKey,
                        contactedBy: device.props.publicKey,
                        localPrivateKey: self.config.deviceKeys.privateKey,
                        configuration: doubleRatchetConfig,
                        initialMessage: ratchetMessage
                    )
                } catch {
                    // TODO: Ignore incoming messages
                    return rekey().flatMapThrowing {
                        throw error
                    }
                }
            }
            
            device.doubleRatchet = ratchet.state
            
            return self.cachedStore.updateDeviceIdentity(device.encrypted).map {
                (data, device)
            }
        }
    }
    
    // TODO: Make internal
    public func p2pConnection(
        _ connection: P2PTransportClient,
        closedWithOptions: Set<P2PTransportClosureOption>
    ) -> EventLoopFuture<Void> {
        func close() -> EventLoopFuture<Void> {
            debugLog("Removing P2P session from active pool")
            guard let index = self.p2pSessions.firstIndex(where: {
                $0.transport === connection
            }) else {
                return self.eventLoop.makeSucceededVoidFuture()
            }
            
            let session = self.p2pSessions.remove(at: index)
            return session.client.disconnect()
        }
        
        debugLog("P2P session disconnecting")
        
        if closedWithOptions.contains(.reconnnectPossible) {
            return connection.reconnect().flatMapError { _ in
                debugLog("Reconnecting P2P connection failed")
                return close()
            }
        }
        
        return close()
    }
    
    internal func _processP2PMessage(
        _ message: SingleCypherMessage,
        remoteMessageId: String,
        sender device: DecryptedModel<DeviceIdentityModel>
    ) -> EventLoopFuture<Void> {
        var subType = message.messageSubtype ?? ""
        
        assert(subType.hasPrefix("_/p2p/0/"))
        
        subType.removeFirst("_/p2p/0/".count)
        
        var components = subType.split(separator: "/")
        
        guard !components.isEmpty else {
            return eventLoop.makeFailedFuture(CypherSDKError.badInput)
        }
        
        let transportId = String(components.removeFirst())
        
        guard let factory = p2pFactories.first(
            where: { $0.transportLayerIdentifier == transportId }
        ) else {
            return eventLoop.makeFailedFuture(CypherSDKError.unsupportedTransport)
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
        
        return factory.receiveMessage(message.text, metadata: message.metadata, handle: handle).map { client in
            // TODO: What is a P2P session already exists?
            if let client = client {
                client.delegate = self
                self.p2pSessions.append(
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
    
    // TODO: Make internal
    public func p2pConnection(
        _ connection: P2PTransportClient,
        receivedMessage buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        guard let session = self.p2pSessions.first(where: {
            $0.transport === connection
        }) else {
            return eventLoop.makeSucceededVoidFuture()
        }
        
        return session.client.receiveBuffer(buffer)
    }
    
    public func listOpenP2PConnections() -> EventLoopFuture<[P2PClient]> {
        return eventLoop.makeSucceededFuture(p2pSessions.map(\.client))
    }
    
    internal func getEstablishedP2PConnection(
        with device: DecryptedModel<DeviceIdentityModel>
    ) -> EventLoopFuture<P2PClient?> {
        return eventLoop.makeSucceededFuture(
            p2pSessions.first(where: {
                $0.deviceId == device.deviceId && $0.username == device.username
            })?.client
        )
    }
    
    internal func createP2PConnection(
        with device: DecryptedModel<DeviceIdentityModel>,
        targetConversation: TargetConversation,
        preferredTransportIdentifier: String? = nil
    ) -> EventLoopFuture<Void> {
        if p2pSessions.contains(where: { $0.deviceId == device.deviceId && $0.username == device.username }) {
            return eventLoop.makeSucceededVoidFuture()
        }
        
        let transportFactory: P2PTransportClientFactory
        
        if let preferredTransportIdentifier = preferredTransportIdentifier {
            guard let defaultTransport = self.p2pFactories.first(where: {
                $0.transportLayerIdentifier == preferredTransportIdentifier
            }) else {
                return eventLoop.makeFailedFuture(CypherSDKError.invalidTransport)
            }
            
            transportFactory = defaultTransport
        } else {
            guard let factory = self.p2pFactories.first else {
                return eventLoop.makeFailedFuture(CypherSDKError.invalidTransport)
            }
            
            transportFactory = factory
        }
        
        let state = P2PFrameworkState(
            username: device.username,
            deviceId: device.deviceId,
            identity: device.identity
        )
        
        return transportFactory.createConnection(
            handle: P2PTransportFactoryHandle(
                transportLayerIdentifier: transportFactory.transportLayerIdentifier,
                messenger: self,
                targetConversation: targetConversation,
                state: state
            )
        ).map { client in
            // TODO: What is a P2P session already exists?
            if let client = client {
                client.delegate = self
                self.p2pSessions.append(
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
