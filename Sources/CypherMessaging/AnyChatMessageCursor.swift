import Foundation

let iterationSize = 50

@available(macOS 10.15, iOS 13, *)
@MainActor final class DeviceChatCursor: Sendable {
    @MainActor internal private(set) var messages = [AnyChatMessage]()
    @MainActor var offset = 0
    let target: TargetConversation
    let conversationId: UUID
    let messenger: CypherMessenger
    let senderId: Int
    let sortMode: SortMode
    @MainActor private var latestOrder: Int?
    @MainActor private(set) var drained = false
    
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
    
    @MainActor fileprivate func popNext() async throws -> AnyChatMessage? {
        while messages.isEmpty {
            if drained {
                return nil
            }

            try await getMore(iterationSize)
        }

        return messages.removeFirst()
    }

    @MainActor fileprivate func dropNext() {
        if !messages.isEmpty {
            messages.removeFirst()
        }
    }

    @MainActor fileprivate func peekNext() async throws -> AnyChatMessage? {
        while messages.isEmpty {
            if drained {
                return nil
            }

            try await getMore(iterationSize)
        }

        return messages.first
    }

    @MainActor fileprivate func getMore(_ limit: Int) async throws {
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

        for message in messages {
            let raw = try messenger.decrypt(message)
            self.messages.append(
                AnyChatMessage(
                    target: target,
                    messenger: messenger,
                    raw: raw
                )
            )
        }
    }
}

@available(macOS 10.15, iOS 13, *)
public final class AnyChatMessageCursor {
    let messenger: CypherMessenger
    private let devices: [DeviceChatCursor]
    let sortMode: SortMode
    
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
    
    @MainActor public func getNext() async throws -> AnyChatMessage? {
        var results = [(Date, DeviceChatCursor)]()

        for device in devices {
            if let message = try await device.peekNext() {
                let sentDate = message.sentDate ?? Date()
                results.append((sentDate, device))
            }
        }

        results.sort { lhs, rhs -> Bool in
            switch self.sortMode {
            case .ascending:
                return lhs.0 < rhs.0
            case .descending:
                return lhs.0 > rhs.0
            }
        }

        guard let deviceCursor = results.first?.1 else {
            return nil
        }

        return try await deviceCursor.popNext()
    }
    
    @MainActor private func _getMore(_ max: Int, joinedWith resultSet: inout [AnyChatMessage]) async throws {
        if max <= 0 {
            return
        }

        for _ in 0..<max {
            guard let message = try await getNext() else {
                return
            }

            resultSet.append(message)
        }
    }
    
    @MainActor public func getMore(_ max: Int) async throws -> [AnyChatMessage] {
        var resultSet = [AnyChatMessage]()
        if max <= 500 {
            resultSet.reserveCapacity(max)
        }
        try await _getMore(max, joinedWith: &resultSet)
        return resultSet
    }
    
    @MainActor public static func readingConversation<Conversation: AnyConversation>(
        _ conversation: Conversation,
        sortMode: SortMode = .descending
    ) async throws -> AnyChatMessageCursor {
        assert(sortMode == .descending, "Unsupported ascending")

        var devices = [DeviceChatCursor]()

        for device in try await conversation.historicMemberDevices() {
            devices.append(
                DeviceChatCursor(
                    target: await conversation.getTarget(),
                    conversationId: conversation.conversation.encrypted.id,
                    messenger: conversation.messenger,
                    senderId: await device.props.senderId,
                    sortMode: sortMode
                )
            )
        }

        devices.append(
            DeviceChatCursor(
                target: await conversation.getTarget(),
                conversationId: conversation.conversation.encrypted.id,
                messenger: conversation.messenger,
                senderId: conversation.messenger.deviceIdentityId,
                sortMode: sortMode
            )
        )

        return AnyChatMessageCursor(
            conversationId: conversation.conversation.encrypted.id,
            messenger: conversation.messenger,
            devices: devices,
            sortMode: sortMode
        )
    }
}
