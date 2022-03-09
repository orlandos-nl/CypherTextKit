import NIO
import CypherProtocol

public struct P2PSendMessage: Codable {
    let message: CypherMessage
    let id: String
}

public struct P2PBroadcast: Codable {
    public struct Message: Codable {
        let origin: Peer
        let target: Peer
        let messageId: String
        let payload: RatchetedCypherMessage
    }
    
    var hops: Int
    let value: Signed<Message>
}

public struct P2PHandshake: Codable {
    let nonce: [UInt8]
}

public enum P2PMessage: Codable {
    case encrypted(Encrypted<P2PPayload>)
    case handshake(P2PHandshake)
}

public struct P2PPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "a"
        case box = "b"
        case ack = "c"
        case id = "d"
    }
    
    private enum MessageType: Int, Codable {
        case status = 0
        case sendMessage = 1
        case ack = 2
        case broadcast = 3
    }
    
    internal enum Box {
        case status(P2PStatusMessage)
        case message(P2PSendMessage)
        case ack
        case broadcast(P2PBroadcast)
    }
    
    let box: Box
    let ack: String
    let id: Int
    
    init(box: Box, ack: String, packetId: Int) {
        self.box = box
        self.ack = ack
        self.id = packetId
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ack, forKey: .ack)
        try container.encode(id, forKey: .id)
        
        switch box {
        case .status(let status):
            try container.encode(MessageType.status, forKey: .type)
            try container.encode(status, forKey: .box)
        case .message(let message):
            try container.encode(MessageType.sendMessage, forKey: .type)
            try container.encode(message, forKey: .box)
        case .ack:
            try container.encode(MessageType.ack, forKey: .type)
        case .broadcast(let message):
            try container.encode(MessageType.broadcast, forKey: .type)
            try container.encode(message, forKey: .box)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ack = try container.decode(String.self, forKey: .ack)
        self.id = try container.decode(Int.self, forKey: .id)
        
        switch try container.decode(MessageType.self, forKey: .type) {
        case .status:
            self.box = try .status(container.decode(P2PStatusMessage.self, forKey: .box))
        case .sendMessage:
            self.box = try .message(container.decode(P2PSendMessage.self, forKey: .box))
        case .ack:
            self.box = .ack
        case .broadcast:
            self.box = try .broadcast(container.decode(P2PBroadcast.self, forKey: .box))
        }
    }
}

public struct P2PStatusMessage: Codable {
    public struct StatusFlags: OptionSet, Codable {
        public let rawValue: Int
        
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        
        public static let isTyping = StatusFlags(rawValue: 1 << 0)
        
        public func encode(to encoder: Encoder) throws {
            try rawValue.encode(to: encoder)
        }
        
        public init(from decoder: Decoder) throws {
            self.rawValue = try Int(from: decoder)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case flags = "a"
        case metadata = "b"
    }
    
    /// StatusFlags contains a bitmap which is used by the SDK to represent typing indicators
    public let flags: StatusFlags
    
    /// Arbirary storage for use by client implementation
    public let metadata: Document
}
