import CypherMessaging

@available(macOS 10.15, iOS 13, *)
public struct ModifyMessagePlugin: Plugin {
    public static let pluginIdentifier = "@/messaging/mutate-history"
    
    @CryptoActor public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        guard
            message.message.messageType == .magic,
            var subType = message.message.messageSubtype,
            subType.hasPrefix("@/messaging/mutate-history/")
        else {
            return nil
        }
        
        subType.removeFirst("@/messaging/mutate-history/".count)
        let remoteId = message.message.text
        let sender = message.sender.username
        
        switch subType {
        case "revoke":
            let message = try await message.conversation.message(byRemoteId: remoteId)
            if message.sender == sender {
                // Message was sent by this user, so the action is permitted
                try await message.remove()
            }
            
            return .ignore
        default:
            return .ignore
        }
    }
    
    @CryptoActor public func onSendMessage(
        _ message: SentMessageContext
    ) async throws -> SendMessageAction? {
        guard
            message.message.messageType == .magic,
            let subType = message.message.messageSubtype,
            subType.hasPrefix("@/messaging/mutate-history/")
        else {
            return nil
        }
        
        return .send
    }
}

@available(macOS 10.15, iOS 13, *)
extension AnyChatMessage {
    @CryptoActor public func revoke() async throws {
        let chat = try await self.target.resolve(in: self.messenger)
        _ = try await chat.sendRawMessage(
            type: .magic,
            messageSubtype: "@/messaging/mutate-history/revoke",
            text: self.raw.encrypted.remoteId,
            preferredPushType: .none
        )
        
        try await self.remove()
    }
}
