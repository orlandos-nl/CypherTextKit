import NIO

public struct P2PMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "a"
        case box = "b"
    }
    
    private enum MessageType: Int, Codable {
        case status = 0
    }
    
    internal enum Box {
        case status(P2PStatusMessage)
    }
    
    let box: Box
    
    init(box: Box) {
        self.box = box
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch box {
        case .status(let status):
            try container.encode(MessageType.status, forKey: .type)
            try container.encode(status, forKey: .box)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        switch try container.decode(MessageType.self, forKey: .type) {
        case .status:
            self.box = try .status(container.decode(P2PStatusMessage.self, forKey: .box))
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
