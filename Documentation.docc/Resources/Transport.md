When making use of CypherTextKit, the SDK relies on your own transport method. 
Our SDK makes use of your own transport system, including API and API Client.

To implement a client, it needs to conform to `CypherServerTransportClient` and implement its functionality.
Some functionalities are optional, in which case they can emit a failed `EventLoopFuture` but not set out the action.

```swift
public protocol CypherServerTransportClient: AnyObject {
    var delegate: CypherTransportClientDelegate? { get set }
    var authenticated: AuthenticationState { get }
    var supportsMultiRecipientMessages: Bool { get }
    
    // Required
    func sendMessage(_ message: RatchetedCypherMessage, toUser username: Username, otherUserDeviceId: DeviceId, messageId: String) -> EventLoopFuture<Void>
    func readKeyBundle(forUsername username: Username) -> EventLoopFuture<UserConfig>
    func publishKeyBundle(_ data: UserConfig) -> EventLoopFuture<Void>
    
    // Optional from here
    func reconnect() -> EventLoopFuture<Void>
    func disconnect() -> EventLoopFuture<Void>
    func requestDeviceRegistery(_ config: UserDeviceConfig) -> EventLoopFuture<Void>
    func sendMessageReadReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void>
    func sendMessageReceivedReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void>
    func publishBlob<C: Codable>(_ blob: C) -> EventLoopFuture<ReferencedBlob<C>>
    func readPublishedBlob<C: Codable>(byId id: String, as type: C.Type) -> EventLoopFuture<ReferencedBlob<C>?>
    func sendMultiRecipientMessage(_ message: MultiRecipientCypherMessage, messageId: String) -> EventLoopFuture<Void>
}
```

### Fields

The `delegate` is a reference to CypherKit's internal objects, and is used to handle events emitted by the server. It required to implement this as `weak`.

`authenticated` should be changed appropriately. If you're offline, or unable to communicate with the server, emit `.unauthenticated`.
The _authenticated_ property is used to determine whether tasks should expect a successful result. Otherwise they won't be attempted until authentication succeeds.
If you use a REST API, without websockets or long polling, make sure to set it to `.authenticated`, Since you can't determine connectivity until the request is sent.

If `supportsMultiRecipientMessages` is **false**, the SDK will make use of private one-on-one messaging for all traffic. 
This is recommended for new implementations, as implementing Multi-Recpient Messaging on the server can be difficult.
Especially with Multi-Device Support, this feature can lead to more overhead in the early stages.
Multi-Recipient Messaging can be enabled at later times as well.

### Required Features

The most important feature that your Transport Client needs to implement is `sendMessage`, which targets _one_ other user's device.

PublishKeyBundle and ReadKeyBundle are required implementations, but _could_ take a variety of forms.
Normally, publishKeyBundle publishes the blob to the server. Another user can then call `readKeyBundle` to retreive those keys and establish contact.
However, custom implementations could make use of a "Contact Card" file, or physical QR codes.

### Optional Features

`requestDeviceRegistery` is used for multi-device support, and requests the master device of the same user to adopt the new device.
Backend implementations _should_ ignore any other requests made by this client, until it's adopted in the **Published KeyBundle**.

Published Blobs are required for **Group Chats**, however the upcoming **Transparent Group Chats** will releive this requirement.

`sendMultiRecipientMessage` sends a single message to many devices and users. This mechanism is used to share chat history with other devices or share large files, without significant network overhead.

### Upgrading Unencrypted Traffic

CypherTextKit can, and recommends, making use of your existing unencrypted transport.
With this comes the consideration that some installed apps do _not yet_ support end-to-end encryption until they update.

As a recommended upgrade path, we advice routing traffic over the existing plaintext transport. You can do so using encodings such as Base64.
For optimal experience, we also recommend adding an `encrypted` flag to messages, if possible.

### In-Memory Testing

You can adopt the `SpoofTransportClient` for in-memory communication in your unit tests. 
This default transport will route information between via an in-memory representation of a server.