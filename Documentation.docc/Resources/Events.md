When creating a CypherMessenger, **EventHandlers** will gain an opportunity to manipulate or react to events.

An EventHandler can prevent a message from being saved, but can also use that opportunity to process magic packets.
Therefore, such a system can also be used to implement a "block user" feature on client level.

EventHandlers need to implement the following protocol:

```swift
public protocol CypherMessengerEventHandler {
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws
    func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction
    func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction
    func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document
    func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document
    func onMessageChange(_ message: AnyChatMessage)
    func onCreateContact(_ contact: Contact, messenger: CypherMessenger)
    func onUpdateContact(_ contact: Contact)
    func onCreateConversation(_ conversation: AnyConversation)
    func onUpdateConversation(_ conversation: AnyConversation)
    func onCreateChatMessage(_ conversation: AnyChatMessage)
    func onContactIdentityChange(username: Username, messenger: CypherMessenger)
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger)
    func onP2PClientClose(messenger: CypherMessenger)
    func onRemoveContact(_ contact: Contact)
    func onRemoveChatMessage(_ message: AnyChatMessage)
    func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) async throws
}
```

Note that the supported types of events may be expanded in the future.
Methods that are `async` will delay further processing until the future is resolved.
