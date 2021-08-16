When creating a CypherMessenger, **EventHandlers** will gain an opportunity to manipulate or react to events.

An EventHandler can prevent a message from being saved, but can also use that opportunity to process magic packets.
Therefore, such a system can also be used to implement a "block user" feature on client level.

EventHandlers need to implement the following protocol:

```swift
public protocol CypherMessengerEventHandler {
    func onRekey(withUser: Username, deviceId: DeviceId) -> EventLoopFuture<Void>
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void>
    func receiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction>
    func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction>
    func onMessageChange(_ message: AnyChatMessage)
    func createPrivateChatMetadata(withUser otherUser: Username) -> EventLoopFuture<Document>
    func createContactMetadata(for username: Username) -> EventLoopFuture<Document>
    func onCreateContact(_ contact: DecryptedModel<Contact>, messenger: CypherMessenger)
    func onCreateConversation(_ conversation: AnyConversation)
    func onCreateChatMessage(_ conversation: AnyChatMessage)
    func onContactIdentityChange(username: Username, messenger: CypherMessenger)
}
```

Note that the supported types of events may be expanded in the future.
Methods that return an `EventLoopFuture` will delay further processing until the future is resolved.