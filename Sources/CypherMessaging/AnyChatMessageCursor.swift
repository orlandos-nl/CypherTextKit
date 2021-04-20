import CypherProtocol
import CypherTransport
import BSON
import Foundation
import NIO

let iterationSize = 50

fileprivate final class DeviceChatCursor {
    internal private(set) var messages = [AnyChatMessage]()
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
    
    public func popNext() -> EventLoopFuture<AnyChatMessage?> {
        if messages.isEmpty {
            if drained {
                return messenger.eventLoop.makeSucceededFuture(nil)
            }
            
            return getMore(iterationSize).flatMap(popNext)
        } else {
            return messenger.eventLoop.makeSucceededFuture(messages.removeFirst())
        }
    }
    
    public func dropNext() {
        if !messages.isEmpty {
            messages.removeFirst()
        }
    }
    
    public func peekNext() -> EventLoopFuture<AnyChatMessage?> {
        if messages.isEmpty {
            if drained {
                return messenger.eventLoop.makeSucceededFuture(nil)
            }
            
            return getMore(iterationSize).flatMap(popNext)
        } else {
            return messenger.eventLoop.makeSucceededFuture(messages.first)
        }
    }
    
    public func getMore(_ limit: Int) -> EventLoopFuture<Void> {
        if drained {
            return messenger.eventLoop.makeSucceededVoidFuture()
        }
        
        return messenger.cachedStore.listChatMessages(
            inConversation: conversationId,
            senderId: senderId,
            sortedBy: sortMode,
            minimumOrder: sortMode == .descending ? latestOrder : nil,
            maximumOrder: sortMode == .ascending ? latestOrder : nil,
            offsetBy: 0,
            limit: limit
        ).map { messages in
            self.latestOrder = messages.last?.order ?? self.latestOrder
            
            self.drained = messages.count < limit
            
            self.messages.append(contentsOf: messages.map { message in
                AnyChatMessage(
                    target: self.target,
                    messenger: self.messenger,
                    raw: self.messenger.decrypt(message)
                )
            })
        }
    }
}

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
    
    public func getNext() -> EventLoopFuture<AnyChatMessage?> {
        struct CursorResult {
            let device: DeviceChatCursor
            let message: AnyChatMessage
        }
        
        let results = devices.map { device -> EventLoopFuture<CursorResult?> in
            device.peekNext().map { message in
                message.map { message in
                    CursorResult(
                        device: device,
                        message: message
                    )
                }
            }
        }
        
        return EventLoopFuture.whenAllSucceed(results, on: messenger.eventLoop).map { results in
            var results = results.compactMap { $0 }
            results.sort { lhs, rhs in
                switch self.sortMode {
                case .ascending:
                    return lhs.message.sendDate < rhs.message.sendDate
                case .descending:
                    return lhs.message.sendDate > rhs.message.sendDate
                }
            }
            return results.first?.message
        }
    }
    
    private func _getMore(_ max: Int, joinedWith resultSet: ResultSet) -> EventLoopFuture<Void> {
        if max <= 0 {
            return messenger.eventLoop.makeSucceededVoidFuture()
        }
        
        return getNext().flatMap { message in
            guard let message = message else {
                return self.messenger.eventLoop.makeSucceededVoidFuture()
            }
            
            resultSet.messages.append(message)
            
            return self._getMore(max - 1, joinedWith: resultSet)
        }
    }
    
    public func getMore(_ max: Int) -> EventLoopFuture<[AnyChatMessage]> {
        let resultSet = ResultSet()
        if max <= 500 {
            resultSet.messages.reserveCapacity(max)
        }
        return _getMore(max, joinedWith: resultSet).map {
            resultSet.messages
        }
    }
    
    public static func readingConversation<Conversation: AnyConversation>(
        _ conversation: Conversation,
        sortMode: SortMode = .descending
    ) -> EventLoopFuture<AnyChatMessageCursor> {
        assert(sortMode == .descending, "Unsupported ascending")
        
        return conversation.memberDevices().map { devices in
            AnyChatMessageCursor(
                conversationId: conversation.conversation.id,
                messenger: conversation.messenger,
                devices: devices.map { device in
                    DeviceChatCursor(
                        target: conversation.target,
                        conversationId: conversation.conversation.id,
                        messenger: conversation.messenger,
                        senderId: device.props.senderId,
                        sortMode: sortMode
                    )
                },
                sortMode: sortMode
            )
        }
    }
}
