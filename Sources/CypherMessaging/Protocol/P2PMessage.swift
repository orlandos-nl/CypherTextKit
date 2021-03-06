import NIO
import CypherProtocol

public struct P2PSendMessage: Codable {
    let message: CypherMessage
    let id: String
}

public struct P2PMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "a"
        case box = "b"
        case ack = "c"
    }
    
    private enum MessageType: Int, Codable {
        case status = 0
        case sendMessage = 1
        case ack = 2
    }
    
    internal enum Box {
        case status(P2PStatusMessage)
        case sendMessage(P2PSendMessage)
        case ack
    }
    
    let box: Box
    let ack: ObjectId
    
    init(box: Box, ack: ObjectId) {
        self.box = box
        self.ack = ack
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch box {
        case .status(let status):
            try container.encode(MessageType.status, forKey: .type)
            try container.encode(status, forKey: .box)
            try container.encode(ack, forKey: .ack)
        case .sendMessage(let message):
            try container.encode(MessageType.sendMessage, forKey: .type)
            try container.encode(message, forKey: .box)
            try container.encode(ack, forKey: .ack)
        case .ack:
            try container.encode(MessageType.ack, forKey: .type)
            try container.encode(ack, forKey: .ack)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ack = try container.decode(ObjectId.self, forKey: .ack)
        
        switch try container.decode(MessageType.self, forKey: .type) {
        case .status:
            self.box = try .status(container.decode(P2PStatusMessage.self, forKey: .box))
        case .sendMessage:
            self.box = try .sendMessage(container.decode(P2PSendMessage.self, forKey: .box))
        case .ack:
            self.box = .ack
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
