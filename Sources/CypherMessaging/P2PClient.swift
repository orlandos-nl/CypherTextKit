import NIO
import BSON
import CypherProtocol

fileprivate actor Ack {
    var id = 0
    
    func next() -> Int {
        defer { id = id &+ 1 }
        return id
    }
}

@available(macOS 12, iOS 15, *)
public final class P2PClient {
    private weak var messenger: CypherMessenger?
    private let client: P2PTransportClient
    let eventLoop: EventLoop
    private let ack = Ack()
    internal private(set) var lastActivity = Date()
    public private(set) var remoteStatus: P2PStatusMessage? {
        didSet {
            _onStatusChange?(remoteStatus)
        }
    }
    private var task: RepeatedTask?
    
    public var username: Username { client.state.username }
    public var deviceId: DeviceId { client.state.deviceId }
    public var isConnected: Bool {
        client.connected == .connected
    }
    private var _onStatusChange: ((P2PStatusMessage?) -> ())?
    private var _onDisconnect: (() -> ())?
    
    public func onDisconnect(perform: @escaping () -> ()) {
        _onDisconnect = perform
    }
    
    public func onStatusChange(perform: @escaping (P2PStatusMessage?) -> ()) {
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
                if let client = self, client.isConnected, client.lastActivity.addingTimeInterval(TimeInterval(seconds)) >= Date() {
                    task.cancel()
                }
            }
        }
        
        debugLog("P2P Connection with \(username) created")
    }
    
    public func receiveBuffer(
        _ buffer: ByteBuffer
    ) async throws {
        guard let messenger = messenger else {
            return
        }
        
        self.lastActivity = Date()
        let document = Document(buffer: buffer)
        
        let ratchetMessage = try BSONDecoder().decode(RatchetedCypherMessage.self, from: document)
        
        let device = try await messenger._fetchDeviceIdentity(for: username, deviceId: deviceId)
        let data = try await device._readWithRatchetEngine(
            ofUser: client.state.username,
            deviceId: client.state.deviceId,
            message: ratchetMessage,
            messenger: messenger
        )
        let messageBson = Document(data: data)
        let message = try BSONDecoder().decode(P2PMessage.self, from: messageBson)
        
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
    
    private func sendMessage(_ box: P2PMessage.Box) async throws {
        guard let messenger = self.messenger else {
            throw CypherSDKError.offline
        }
        
        self.lastActivity = Date()
        
        let message = P2PMessage(
            box: box,
            ack: await ack.next()
        )
        
        return try await messenger._writeWithRatchetEngine(
            ofUser: client.state.username,
            deviceId: client.state.deviceId
        ) { ratchetEngine, rekey in
            let messageBson = try BSONEncoder().encode(message)
            let encryptedMessage = try ratchetEngine.ratchetEncrypt(messageBson.makeData())
            let signedMessage = try messenger._signRatchetMessage(encryptedMessage, rekey: rekey)
            let signedMessageBson = try BSONEncoder().encode(signedMessage)
            
            return try await self.client.sendMessage(signedMessageBson.makeByteBuffer())
        }
    }
    
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
