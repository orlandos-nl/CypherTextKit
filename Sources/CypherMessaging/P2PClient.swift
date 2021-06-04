import NIO
import BSON

public final class P2PClient {
    private weak var messenger: CypherMessenger?
    private let client: P2PTransportClient
    let eventLoop: EventLoop
    internal private(set) var lastActivity = Date()
    public private(set) var remoteStatus: P2PStatusMessage?
    private var task: RepeatedTask?
    
    public var isConnected: Bool {
        client.connected == .connected
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
    }
    
    public func receiveBuffer(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        guard let messenger = messenger else {
            return eventLoop.makeSucceededVoidFuture()
        }
        
        self.lastActivity = Date()
        let document = Document(buffer: buffer)
        
        do {
            let ratchetMessage = try BSONDecoder().decode(RatchetedCypherMessage.self, from: document)
            
            return messenger._readWithRatchetEngine(
                ofUser: client.state.username,
                deviceId: client.state.deviceId,
                message: ratchetMessage
            ).flatMapThrowing { data, _ in
                let messageBson = Document(data: data)
                let message = try BSONDecoder().decode(P2PMessage.self, from: messageBson)
                
                switch message.box {
                case .status(let status):
                    self.remoteStatus = status
                }
            }
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }
    
    public func updateStatus(
        flags: P2PStatusMessage.StatusFlags,
        metadata: Document = [:]
    ) -> EventLoopFuture<Void> {
        guard let messenger = messenger else {
            return eventLoop.makeSucceededVoidFuture()
        }
        
        self.lastActivity = Date()
        let message = P2PMessage(
            box: .status(
                P2PStatusMessage(
                    flags: .isTyping,
                    metadata: metadata
                )
            )
        )
        
        return messenger._writeWithRatchetEngine(
            ofUser: client.state.username,
            deviceId: client.state.deviceId
        ) { ratchetEngine, rekey -> EventLoopFuture<Void> in
            do {
                let messageBson = try BSONEncoder().encode(message)
                let encryptedMessage = try ratchetEngine.ratchetEncrypt(messageBson.makeData())
                let signedMessage = try messenger._signRatchetMessage(encryptedMessage, rekey: rekey)
                let signedMessageBson = try BSONEncoder().encode(signedMessage)
                
                return self.client.sendMessage(signedMessageBson.makeByteBuffer())
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        }
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        client.disconnect().map {
            if let messenger = self.messenger {
                messenger.eventHandler.onP2PClientClose(messenger: messenger)
            }
        }
    }
    
    deinit {
        task?.cancel()
    }
}
