import Crypto
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
    private var handshakeSent = false
    private let encryptionKey: SymmetricKey
    private var inboundPacketId = 0
    private var outboundPacketId = 0
    private let encryptionNonce = SymmetricKey(size: .bits256).withUnsafeBytes { buffer in
        Array(buffer.bindMemory(to: UInt8.self))
    }
    private var decryptionKey: SymmetricKey?
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
    
    @CypherTextKitActor internal init(
        client: P2PTransportClient,
        messenger: CypherMessenger,
        closeInactiveAfter seconds: Int?
    ) async throws {
        self.messenger = messenger
        self.client = client
        self.eventLoop = messenger.eventLoop
        
        let sharedSecret = try messenger._formSharedSecret(with: client.state.remote.publicKey)
        encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: encryptionNonce,
            sharedInfo: "p2p".data(using: .utf8)!,
            outputByteCount: 32
        )
        
        await messenger.eventHandler.onP2PClientOpen(self, messenger: messenger)
        
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
        
        guard buffer.readableBytes <= 100_000 else {
            // Ignore packets over 100KB
            // While BSON is a fast parser that does no unnecessary copies
            // We should still protect memory
            return
        }
        
        // TODO: DOS prevention against repeating malicious peers
        
        self.lastActivity = Date()
        let document = Document(buffer: buffer)
        
        let packet = try BSONDecoder().decode(P2PMessage.self, from: document)
        
        switch packet {
        case .encrypted(let encryptedMessage):
            if let decryptionKey = decryptionKey {
                let message = try encryptedMessage.decrypt(using: decryptionKey)
                
                guard message.id == inboundPacketId else {
                    // Replay attack?
                    return await disconnect()
                }
                
                inboundPacketId += 1
                return try await receiveDecryptedPayload(message)
            } else {
                debugLog("Cannot decrypt message without key")
            }
        case .handshake(let handshake):
            let sharedSecret = try messenger._formSharedSecret(with: client.state.remote.publicKey)
            decryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA512.self,
                salt: handshake.nonce,
                sharedInfo: "p2p".data(using: .utf8)!,
                outputByteCount: 32
            )
            inboundPacketId = 0
        }
    }
    
    @CypherTextKitActor private func receiveDecryptedPayload(
        _ message: P2PPayload
    ) async throws {
        guard let messenger = messenger else {
            return
        }
        
        switch message.box {
        case .status(let status):
            self.remoteStatus = status
        case .message(let message):
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
                broadcast.value.value.makeByteBuffer().readableBytes <= P2PClient.maximumMeshPacketSize + 2_000,
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
            let knownDevices = try await messenger._fetchKnownDeviceIdentities(for: claimedOrigin.username)
            let verified: Bool
            
            if let knownPeer = knownDevices.first(where: { $0.deviceId == claimedOrigin.deviceId }) {
                // Device is known, accept!
                broadcastMessage = try signedBroadcast.readAndVerifySignature(signedBy: knownPeer.identity)
                verified = true
            } else if knownDevices.isEmpty {
                // User is not known, so assume the device is plausible although unverified
                broadcastMessage = try signedBroadcast.readAndVerifySignature(signedBy: claimedOrigin.identity)
                verified = false
            } else {
                // User is known, but device is not known. Abort, might be malicious
                return
            }
            
            if destination.username == messenger.username && destination.deviceId == messenger.deviceId {
                // It's for us!
                try await messenger._queueTask(
                    .processMessage(
                        ReceiveMessageTask(
                            message: broadcastMessage.payload,
                            messageId: broadcastMessage.messageId,
                            sender: claimedOrigin.username,
                            deviceId: claimedOrigin.deviceId,
                            createdAt: broadcastMessage.createdAt
                        )
                    )
                )
                
                // TODO: Broadcast ack back? How does the client know it's arrived?
            }
            
            let p2pConnections = messenger.listOpenP2PConnections()
            
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
            .message(
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
    internal func sendMessage(_ box: P2PPayload.Box) async throws {
        if !handshakeSent {
            handshakeSent = true
            try await sendHandshake()
        }
        
        self.lastActivity = Date()
        let ack = await ack.next(on: eventLoop)
        
        let payload = P2PPayload(
            box: box,
            ack: ack.id,
            packetId: outboundPacketId
        )
        outboundPacketId += 1
        
        let message = try P2PMessage.encrypted(
            Encrypted<P2PPayload>(
                payload,
                encryptionKey: encryptionKey
            )
        )
        
        let signedMessageBson = try BSONEncoder().encode(message)
        try await self.client.sendMessage(signedMessageBson.makeByteBuffer())
        
        try await ack.completion()
    }
    
    /// Sends a message (cleartext) to a remote peer
    /// This function then applies end-to-end encryption before transmitting the information over the internet.
    private func sendHandshake() async throws {
        let message = P2PMessage.handshake(P2PHandshake(nonce: encryptionNonce))
        let signedMessageBson = try BSONEncoder().encode(message)
        outboundPacketId = 0
        try await self.client.sendMessage(signedMessageBson.makeByteBuffer())
    }
    
    /// Disconnects the transport layer
    public func disconnect() async {
        if let messenger = self.messenger {
            await messenger.eventHandler.onP2PClientClose(messenger: messenger)
        }
        
        await client.disconnect()
        _onDisconnect?()
    }
    
    deinit {
        task?.cancel()
    }
}
