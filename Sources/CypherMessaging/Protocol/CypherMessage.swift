@available(macOS 12, iOS 15, *)
struct CypherMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "a"
        case box = "b"
    }
    
    private enum WrappedType: Int, Codable {
        case single = 0
        case array = 1
    }
    
    internal enum Wrapped {
        case single(SingleCypherMessage)
        case array([SingleCypherMessage])
    }
    
    let box: Wrapped
    
    init(message: SingleCypherMessage) {
        self.box = .single(message)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch box {
        case .single(let message):
            try container.encode(WrappedType.single, forKey: .type)
            try container.encode(message, forKey: .box)
        case .array(let messages):
            try container.encode(WrappedType.array, forKey: .type)
            try container.encode(messages, forKey: .box)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        switch try container.decode(WrappedType.self, forKey: .type) {
        case .single:
            try self.box = .single(container.decode(SingleCypherMessage.self, forKey: .box))
        case .array:
            try self.box = .array(container.decode([SingleCypherMessage].self, forKey: .box))
        }
    }
}
