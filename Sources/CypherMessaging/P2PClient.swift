import BSON

public final class P2PClient {
    private weak var messenger: CypherMessenger?
    private let client: P2PTransportClient
    let eventLoop: EventLoop
    public private(set) var remoteStatus: P2PStatusMessage?
    
    internal init(client: P2PTransportClient, messenger: CypherMessenger) {
        self.messenger = messenger
        self.client = client
        self.eventLoop = messenger.eventLoop
    }
    
    public func receiveBuffer(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        guard let messenger = messenger else {
            return eventLoop.makeSucceededVoidFuture()
        }
        
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
}
