import NIO
import BSON
import CypherProtocol

struct Acknowledgement {
    public let id: String
    fileprivate let done: EventLoopFuture<Void>
    
    public func completion() async throws {
        try await done.get()
    }
}

fileprivate final actor AcknowledgementManager {
    var acks = [String: EventLoopPromise<Void>]()
    
    func next(on eventLoop: EventLoop, deadline: TimeAmount = .seconds(10)) -> Acknowledgement {
        let id = UUID().uuidString
        let promise = eventLoop.makePromise(of: Void.self)
        acks[id] = promise
        
        eventLoop.scheduleTask(in: deadline) {
            promise.succeed(())
        }
        
        return Acknowledgement(id: id, done: promise.futureResult)
    }
    
    func acknowledge(_ id: String) {
        acks[id]?.succeed(())
    }
    
    deinit {
        struct Timeout: Error {}
        
        for (_, ack) in acks {
            ack.fail(Timeout())
        }
    }
}

fileprivate struct ForwardedBroadcast: Hashable {
    let username: Username
    let deviceId: DeviceId
    let messageId: String
}

/// A peer-to-peer connection with a remote device. Used for low-latency communication with a third-party device.
/// P2PClient is also used for static-length packets that are easily identified, such as status changes.
///
/// You can interact with P2PClient as if you're sending and receiving cleartext messages, while the client itself applies the end-to-end encryption.
@available(macOS 10.15, iOS 13, *)
public final class P2PClient {
    public static let maximumMeshPacketSize = 16_000
    private weak var messenger: CypherMessenger?
    private let client: P2PTransportClient
    let eventLoop: EventLoop
    private let ack = AcknowledgementManager()
    internal private(set) var lastActivity = Date()
    public var isMeshEnabled: Bool { client.state.isMeshEnabled }
    @CypherTextKitActor private var forwardedBroadcasts = [ForwardedBroadcast]()
    public private(set) var remoteStatus: P2PStatusMessage? {
        didSet {
            _onStatusChange?(remoteStatus)
        }
    }
    private var task: RepeatedTask?
    
    /// The username of the remote device to which this P2PClient is connected
    public var username: Username { client.state.username }
    
    /// The devieId of the remote device to which this P2PClient is connected
    public var deviceId: DeviceId { client.state.deviceId }
    
    public var isConnected: Bool {
        client.connected == .connected
    }
    private var _onStatusChange: (@Sendable (P2PStatusMessage?) -> ())?
    private var _onDisconnect: (@Sendable () -> ())?
    
    /// The provided closure is called when the client disconnects
    public func onDisconnect(perform: @escaping @Sendable () -> ()) {
        _onDisconnect = perform
    }
    
    /// The provided closure is called when the remote device indicates it's status has changed
    public func onStatusChange(perform: @escaping @Sendable (P2PStatusMessage?) -> ()) {
        _onStatusChange = perform
    }
    
    internal init(
        client: P2PTransportClient,
        messenger: CypherMessenger,
        closeInactiveAfter seconds: Int?
    ) {
        self.messenger = messenger
        self.client = client
        self.eventLoop = messenger.eventLoop
        
        messenger.eventHandler.onP2PClientOpen(self, messenger: messenger)
        
        if let seconds = seconds {
            assert(seconds > 0 && seconds <= 3600, "Invalid inactivity timer")
            
            self.task = eventLoop.scheduleRepeatedTask(
                initialDelay: .seconds(30),
                delay: .seconds(30)
            ) { [weak self] task in
                if
                    let client = self,
                    client.isConnected,
                    client.lastActivity.addingTimeInterval(TimeInterval(seconds)) >= Date()
                {
                    Task.detached {
                        await client.disconnect()
                    }
                    task.cancel()
                }
            }
        }
        
        debugLog("P2P Connection with \(username) created")
    }
    
    /// This function is called whenever a P2PTransportClient receives information from a remote device
    @CypherTextKitActor internal func receiveBuffer(
        _ buffer: ByteBuffer
    ) async throws {
        guard let messenger = messenger else {
            return
        }
        
        // TODO: DOS prevention against repeating malicious peers
        
        self.lastActivity = Date()
        let document = Document(buffer: buffer)
        
        // TODO: Replace this with symmetric key decryption?
//        let ratchetMessage = try BSONDecoder().decode(RatchetedCypherMessage.self, from: document)
//
//        let device = try await messenger._fetchDeviceIdentity(for: username, deviceId: deviceId)
//        let data = try await device._readWithRatchetEngine(
//            message: ratchetMessage,
//            messenger: messenger
//        )
//        let messageBson = Document(data: data)
//        let message = try BSONDecoder().decode(P2PMessage.self, from: messageBson)
        let message = try BSONDecoder().decode(P2PMessage.self, from: document)
        
        switch message.box {
        case .status(let status):
            self.remoteStatus = status
        case .sendMessage(let message):
            let device = try await messenger._fetchDeviceIdentity(for: username, deviceId: deviceId)
            let messageId = message.id
            switch message.message.box {
            case .single(let message):
                try await messenger._processMessage(
                    message: message,
                    remoteMessageId: messageId,
                    sender: device
                )
            case .array(let messages):
                for message in messages {
                    try await messenger._processMessage(
                        message: message,
                        remoteMessageId: messageId,
                        sender: device
                    )
                }
            }
        case .ack:
            await ack.acknowledge(message.ack)
        case .broadcast(var broadcast):
            guard
                // Ignore broadcasts on non-mesh clients
                client.state.isMeshEnabled,
                // 2KB packaging overhead over payload
                buffer.readableBytes <= P2PClient.maximumMeshPacketSize + 2_000,
                // Prevent infinite hopping
                broadcast.hops <= 64
            else {
                // Ignore broadcast
                return
            }
            
            broadcast.hops -= 1
            let signedBroadcast = broadcast.value
            let unverifiedBroadcast = try signedBroadcast.readWithoutVerifying()
            let claimedOrigin = unverifiedBroadcast.origin
            let destination = unverifiedBroadcast.target
            
            // TODO: Prevent Denial-of-Service spammers from spamming us through the mesh
            
            let forwardedBroadcast = ForwardedBroadcast(
                username: claimedOrigin.username,
                deviceId: claimedOrigin.deviceId,
                messageId: unverifiedBroadcast.messageId
            )
            
            guard !forwardedBroadcasts.contains(forwardedBroadcast) else {
                // Don't re-process the same message
                return
            }
            
            forwardedBroadcasts.append(forwardedBroadcast)
            
            if forwardedBroadcasts.count > 200 {
                // Clean up historic broadcasts list in bulk
                // To clean up memory, and to allow re-broadcasts in case things changed
                forwardedBroadcasts.removeFirst(100)
            }
            
            let broadcastMessage: P2PBroadcast.Message
            let deviceModel: DecryptedModel<DeviceIdentityModel>
            let knownDevices = try await messenger._fetchKnownDeviceIdentities(for: claimedOrigin.username)
            
            if let knownPeer = knownDevices.first(where: { $0.deviceId == claimedOrigin.deviceId }) {
                // Device is known, accept!
                deviceModel = knownPeer
                broadcastMessage = try signedBroadcast.readAndVerifySignature(signedBy: knownPeer.identity)
            } else if knownDevices.isEmpty {
                // User is not known, so assume the device is plausible although unverified
                broadcastMessage = try signedBroadcast.readAndVerifySignature(signedBy: claimedOrigin.identity)
                deviceModel = try await messenger._createDeviceIdentity(
                    from: claimedOrigin.deviceConfig,
                    forUsername: claimedOrigin.username,
                    serverVerified: false
                )
            } else {
                // User is known, but device is not known. Abort, might be malicious
                return
            }
            
            if destination.username == messenger.username && destination.deviceId == messenger.deviceId {
                // It's for us!
                let payloadData = try await deviceModel._readWithRatchetEngine(message: broadcastMessage.payload, messenger: messenger)
                let message = try BSONDecoder().decode(CypherMessage.self, from: Document(data: payloadData))
                
                switch message.box {
                case .single(let message):
                    try await messenger._processMessage(
                        message: message,
                        remoteMessageId: broadcastMessage.messageId,
                        sender: deviceModel
                    )
                case .array(let messages):
                    for message in messages {
                        try await messenger._processMessage(
                            message: message,
                            remoteMessageId: broadcastMessage.messageId,
                            sender: deviceModel
                        )
                    }
                }
                
                // TODO: Broadcast ack back? How does the client know it's arrived?
            }
            
            let p2pConnections = await messenger.listOpenP2PConnections()
            
            if let p2pConnection = p2pConnections.first(where: {
                $0.client.state.username == destination.username && $0.client.state.deviceId == destination.deviceId
            }) {
                // We know who to send it to!
                return try await p2pConnection.sendMessage(.broadcast(broadcast))
            }
            
            if broadcast.hops <= 0 {
                // End of reach, let's stop here
                return
            }
            
            // Try to pass it on to other peers, maybe they can help
            for p2pConnection in p2pConnections {
                if p2pConnection.username == client.state.username && p2pConnection.deviceId == client.state.deviceId {
                    // Ignore, since we're just cascading it back to the origin of this broadcast
                } else {
                    let broadcast = broadcast
                    Task {
                        // Ignore (connection) errors, we've tried our best
                        try await p2pConnection.sendMessage(.broadcast(broadcast))
                    }
                }
            }
            
            // TODO: Forward to/broadcast to the internet services?
        }
    }
    
    func sendMessage(_ message: CypherMessage, messageId: String) async throws {
        debugLog("Routing message over P2P", message)
        try await sendMessage(
            .sendMessage(
                P2PSendMessage(
                    message: message,
                    id: messageId
                )
            )
        )
    }
    
    /// Emits a status update to the remote peer
    public func updateStatus(
        flags: P2PStatusMessage.StatusFlags,
        metadata: Document = [:]
    ) async throws {
        try await sendMessage(
            .status(
                P2PStatusMessage(
                    flags: flags,
                    metadata: metadata
                )
            )
        )
    }
    
    /// Sends a message (cleartext) to a remote peer
    /// This function then applies end-to-end encryption before transmitting the information over the internet.
    internal func sendMessage(_ box: P2PMessage.Box) async throws {
        guard let messenger = self.messenger else {
            throw CypherSDKError.offline
        }
        
        self.lastActivity = Date()
        let ack = await ack.next(on: eventLoop)
        
        let message = P2PMessage(
            box: box,
            ack: ack.id
        )
        
        // TODO: Replace this with symmetric key encryption? Make sure to prevent replay attacks
//        try await messenger._writeWithRatchetEngine(
//            ofUser: client.state.username,
//            deviceId: client.state.deviceId
//        ) { ratchetEngine, rekey in
//            let messageBson = try BSONEncoder().encode(message)
//            let encryptedMessage = try ratchetEngine.ratchetEncrypt(messageBson.makeData())
//            let signedMessage = try await messenger._signRatchetMessage(encryptedMessage, rekey: rekey)
//            let signedMessageBson = try BSONEncoder().encode(signedMessage)
//
//            try await self.client.sendMessage(signedMessageBson.makeByteBuffer())
//        }
        let signedMessageBson = try BSONEncoder().encode(message)
        try await self.client.sendMessage(signedMessageBson.makeByteBuffer())
        
        try await ack.completion()
    }
    
    /// Disconnects the transport layer
    public func disconnect() async {
        if let messenger = self.messenger {
            messenger.eventHandler.onP2PClientClose(messenger: messenger)
        }
        
        await client.disconnect()
        _onDisconnect?()
    }
    
    deinit {
        task?.cancel()
    }
}
