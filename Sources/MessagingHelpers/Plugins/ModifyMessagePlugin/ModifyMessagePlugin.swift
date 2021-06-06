import CypherMessaging

public struct ModifyMessagePlugin: Plugin {
    public static let pluginIdentifier = "@/messaging/mutate-history"
    
    public func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?> {
        guard
            message.message.messageType == .magic,
            var subType = message.message.messageSubtype,
            subType.hasPrefix("@/messaging/mutate-history/")
        else {
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        subType.removeFirst("@/messaging/mutate-history/".count)
        let remoteId = message.message.text
        let sender = message.sender.username
        let messenger = message.messenger
        
        switch subType {
        case "revoke":
            return message.conversation.message(byRemoteId: remoteId).flatMap { message in
                guard message.senderUser == sender else {
                    // Message is not sent by this user
                    return messenger.eventLoop.makeSucceededVoidFuture()
                }
                
                return message.destroy()
            }.map {
                .ignore
            }
        default:
            return messenger.eventLoop.makeSucceededFuture(.ignore)
        }
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) -> EventLoopFuture<SendMessageAction?> {
        guard
            message.message.messageType == .magic,
            let subType = message.message.messageSubtype,
            subType.hasPrefix("@/messaging/mutate-history/")
        else {
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        return message.messenger.eventLoop.makeSucceededFuture(.send)
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
}

extension AnyChatMessage {
    public func revoke() -> EventLoopFuture<Void> {
        self.target.resolve(in: self.messenger).flatMap { chat in
            chat.sendRawMessage(
                type: .magic,
                messageSubtype: "@/messaging/mutate-history/revoke",
                text: self.remoteId,
                preferredPushType: .none
            )
        }.flatMap { _ in
            self.destroy()
        }
    }
}
