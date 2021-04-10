import BSON
import Foundation
import Crypto
import NIO
import CypherProtocol
import CypherTransport

public enum DeviceRegisteryMode: Int, Codable {
    case masterDevice, childDevice, unregistered
}

fileprivate struct _CypherMessengerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case databaseEncryptionKey = "a"
        case deviceKeys = "b"
        case username = "c"
        case registeryMode = "d"
    }
    
    let databaseEncryptionKey: Data
    let deviceKeys: DevicePrivateKeys
    let username: Username
    var registeryMode: DeviceRegisteryMode
}

enum RekeyState {
    case rekey, next
}

public struct TransportCreationRequest {
    public let username: Username
    public let deviceId: DeviceId
    public let userConfig: UserConfig
    public let signingIdentity: PrivateSigningKey
}

public final class CypherMessenger: CypherTransportClientDelegate {
    public let eventLoop: EventLoop
    private(set) var jobQueue: JobQueue!
    private let config: _CypherMessengerConfig
    internal let eventHandler: CypherMessengerEventHandler
    internal let cachedStore: _CypherMessengerStoreCache
    internal let transport: CypherServerTransportClient
    internal let databaseEncryptionKey: SymmetricKey
    
    public var authenticated: AuthenticationState { transport.authenticated }
    public var username: Username { config.username }
    public var deviceId: DeviceId { config.deviceKeys.deviceId }
    
    private init(
        eventLoop: EventLoop,
        delegate: CypherMessengerEventHandler,
        config: _CypherMessengerConfig,
        database: CypherMessengerStore,
        transport: CypherServerTransportClient
    ) {
        self.eventLoop = eventLoop
        self.eventHandler = delegate
        self.config = config
        self.cachedStore = _CypherMessengerStoreCache(base: database, eventLoop: eventLoop)
        self.transport = transport
        self.databaseEncryptionKey = SymmetricKey(data: config.databaseEncryptionKey)
        self.transport.delegate = self
        self.jobQueue = JobQueue(messenger: self, database: self.cachedStore, databaseEncryptionKey: self.databaseEncryptionKey)
        
        _ = self.transport.reconnect()
    }
    
    public static func registerMessenger<
        Transport: CypherServerTransportClient
    >(
        username: Username,
        appPassword: String,
        usingTransport createTransport: @escaping (TransportCreationRequest) -> EventLoopFuture<Transport>,
        database: CypherMessengerStore,
        delegate: CypherMessengerEventHandler,
        on eventLoop: EventLoop
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
            registeryMode: .unregistered
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
                        delegate: delegate,
                        config: config,
                        database: database,
                        transport: transport
                    )
                    
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
                            delegate: delegate,
                            config: config,
                            database: database,
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
        database: CypherMessengerStore,
        delegate: CypherMessengerEventHandler,
        on eventLoop: EventLoop
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
            database: database,
            delegate: delegate,
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
        database: CypherMessengerStore,
        delegate: CypherMessengerEventHandler,
        on eventLoop: EventLoop
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
            database: database,
            delegate: delegate,
            on: eventLoop
        )
    }
    
    public static func resumeMessenger<
        Transport: CypherServerTransportClient
    >(
        appPassword: String,
        usingTransport createTransport: @escaping (TransportCreationRequest) -> EventLoopFuture<Transport>,
        database: CypherMessengerStore,
        delegate: CypherMessengerEventHandler,
        on eventLoop: EventLoop
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
                        delegate: delegate,
                        config: config,
                        database: database,
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
    
    // TODO: Make internal
    public func receiveServerEvent(_ event: CypherServerEvent) -> EventLoopFuture<Void> {
        switch event {
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
                                    CypherMessage(
                                        messageType: .magic,
                                        messageSubtype: "devices/announce",
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
        forDevices devices: [DecryptedModel<DeviceIdentity>]
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
    
    private func _writeWithRatchetEngine<T>(
        ofDevice device: DecryptedModel<DeviceIdentity>,
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
    ) -> EventLoopFuture<(Data, DecryptedModel<DeviceIdentity>)> {
        self._fetchDeviceIdentity(for: username, deviceId: deviceId).flatMap { device in
            let data: Data
            var ratchet: DoubleRatchetHKDF<SHA512>
            if let existingState = device.doubleRatchet {
                ratchet = DoubleRatchetHKDF(
                    state: existingState,
                    configuration: doubleRatchetConfig
                )
                
                do {
                    let ratchetMessage = try message.readAndValidate(usingIdentity: device.props.identity)
                    data = try ratchet.ratchetDecrypt(ratchetMessage)
                } catch {
                    return self.eventLoop.makeFailedFuture(error)
                }
            } else {
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
                    return self.eventLoop.makeFailedFuture(error)
                }
            }
            
            device.doubleRatchet = ratchet.state
            
            return self.cachedStore.updateDeviceIdentity(device.encrypted).map {
                (data, device)
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
