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
        let document = Document(buffer: buffer)
        
        do {
            let signedMessage = try BSONDecoder().decode(Signed<P2PMessage>.self, from: document)
            let message = try signedMessage.readAndVerifySignature(signedBy: client.state.identity)
            
            switch message.box {
            case .status(let status):
                self.remoteStatus = status
            }
            
            return eventLoop.makeSucceededVoidFuture()
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
        
        do {
            let signedMessage = try messenger.sign(message)
            let bson = try BSONEncoder().encode(signedMessage)
            
            return client.sendMessage(bson.makeByteBuffer())
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }
}
