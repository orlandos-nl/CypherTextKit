import CypherProtocol
import BSON
import Foundation
import NIO

let iterationSize = 50

@available(macOS 12, iOS 15, *)
fileprivate final class DeviceChatCursor {
    internal private(set) var messages = [AnyChatMessage]()
    var offset = 0
    let target: TargetConversation
    let conversationId: UUID
    let messenger: CypherMessenger
    let senderId: Int
    let sortMode: SortMode
    private var latestOrder: Int?
    public private(set) var drained = false
    
    fileprivate init(
        target: TargetConversation,
        conversationId: UUID,
        messenger: CypherMessenger,
        senderId: Int,
        sortMode: SortMode
    ) {
        self.target = target
        self.conversationId = conversationId
        self.messenger = messenger
        self.senderId = senderId
        self.sortMode = sortMode
    }
    
    public func popNext() async throws -> AnyChatMessage? {
        if messages.isEmpty {
            if drained {
                return nil
            }
            
            try await getMore(iterationSize)
            return try await popNext()
        } else {
            return messages.removeFirst()
        }
    }
    
    public func dropNext() {
        if !messages.isEmpty {
            messages.removeFirst()
        }
    }
    
    public func peekNext() async throws -> AnyChatMessage? {
        if messages.isEmpty {
            if drained {
                return nil
            }
            
            try await getMore(iterationSize)
            return try await peekNext()
        } else {
            return messages.first
        }
    }
    
    public func getMore(_ limit: Int) async throws {
        if drained { return }
        
        let messages = try await messenger.cachedStore.listChatMessages(
            inConversation: conversationId,
            senderId: senderId,
            sortedBy: sortMode,
            minimumOrder: sortMode == .descending ? latestOrder : nil,
            maximumOrder: sortMode == .ascending ? latestOrder : nil,
            offsetBy: self.offset,
            limit: limit
        )
        self.latestOrder = messages.last?.order ?? self.latestOrder
        
        self.drained = messages.count < limit
        
        self.offset += messages.count
        self.messages.append(contentsOf: messages.map { message in
            AnyChatMessage(
                target: self.target,
                messenger: self.messenger,
                raw: self.messenger.decrypt(message)
            )
        })
    }
}

@available(macOS 12, iOS 15, *)
public final class AnyChatMessageCursor {
    let messenger: CypherMessenger
    private let devices: [DeviceChatCursor]
    let sortMode: SortMode
    
    private final class ResultSet {
        var messages = [AnyChatMessage]()
    }
    
    private init(
        conversationId: UUID,
        messenger: CypherMessenger,
        devices: [DeviceChatCursor],
        sortMode: SortMode
    ) {
        self.messenger = messenger
        self.devices = devices
        self.sortMode = sortMode
    }
    
    public func getNext() async throws -> AnyChatMessage? {
        struct CursorResult {
            let device: DeviceChatCursor
            let message: AnyChatMessage
        }
        
        var results = try await devices.asyncCompactMap { device -> CursorResult? in
            try await device.peekNext().map { message in
                CursorResult(
                    device: device,
                    message: message
                )
            }
        }
        
        results.sort { lhs, rhs in
            switch self.sortMode {
            case .ascending:
                return lhs.message.sendDate < rhs.message.sendDate
            case .descending:
                return lhs.message.sendDate > rhs.message.sendDate
            }
        }
        
        guard let result = results.first else {
            return nil
        }
        
        return try await result.device.popNext()
    }
    
    private func _getMore(_ max: Int, joinedWith resultSet: ResultSet) async throws {
        if max <= 0 {
            return
        }
        
        guard let message = try await getNext() else {
            return
        }
        
        resultSet.messages.append(message)
        
        try await self._getMore(max - 1, joinedWith: resultSet)
    }
    
    public func getMore(_ max: Int) async throws -> [AnyChatMessage] {
        let resultSet = ResultSet()
        if max <= 500 {
            resultSet.messages.reserveCapacity(max)
        }
        try await _getMore(max, joinedWith: resultSet)
        return resultSet.messages
    }
    
    public static func readingConversation<Conversation: AnyConversation>(
        _ conversation: Conversation,
        sortMode: SortMode = .descending
    ) async throws -> AnyChatMessageCursor {
        assert(sortMode == .descending, "Unsupported ascending")
        
        var devices = try await conversation.memberDevices().map { device in
            DeviceChatCursor(
                target: conversation.target,
                conversationId: conversation.conversation.id,
                messenger: conversation.messenger,
                senderId: device.props.senderId,
                sortMode: sortMode
            )
        }
        devices.append(
            DeviceChatCursor(
                target: conversation.target,
                conversationId: conversation.conversation.id,
                messenger: conversation.messenger,
                senderId: conversation.messenger.deviceIdentityId,
                sortMode: sortMode
            )
        )
        
        return AnyChatMessageCursor(
            conversationId: conversation.conversation.id,
            messenger: conversation.messenger,
            devices: devices,
            sortMode: sortMode
        )
    }
}
