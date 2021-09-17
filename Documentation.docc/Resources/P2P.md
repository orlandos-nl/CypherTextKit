Peer to Peer (P2P) communication is used to mask small packets such as **typing indicators**.
By adopting P2P connections, you reduce server load while improving the security of communications.

P2P Communication is handled completely through the framework's `P2PClient` instances.
The P2PClient internally manages encryption and decryption, but sends and received data over a `P2PTransportClient`.

One app/messenger can support multiple P2P transports at the same time.
A P2PTransportClient are created when a `P2PTransportClientFactory` is registered with the messenger.
The messenger then approaches the factory with a request to establish a connection.

### Implementation

CypherTextKit currently supports one Peer-to-Peer transport client; `IPv6TCPP2PTransportClient`.
As its name suggests, this creates a connection via IPv6 TCP connections.

### Upcoming Implementations

As part of CypherTextKit, we strive to implement a wider variety of transports per platform.
This includes:

1. WebRTC (iOS, macOS, Android, Linux, Windows)
2. Multipeer Connectivity (iOS & macOS)

### In-Memory Testing

You can adopt the `SpoofP2PTransportClient` for in-memory P2P communication. This is only useful for testing.

### Custom Implementations

You can create a custom P2PTransportClient by setting up a full-duplex communication channel.
The transport layer must be able to receive binary data, which is emitted to the weakly captured `delegate`.
It must also be able to send binary data to the other party, and support disconnection.

The P2PTransportClient is created from a registered **IPv6TCPP2PTransportClientFactory**.
The factory gains the opportunity to send magic packets to the other party inside `createConnection`:

```swift
func createConnection(
  handle: P2PTransportFactoryHandle
) async throws -> P2PTransportClient? {
  ..
}
```

The handle should send any necessary info, for example your IP addresses and port, to the other party. 
For WebRTC based traffic, this would consist of their SDP.

If a client cannot immediately awaits a response before creating a connection, it has three options:

1. Delay the result of `onConnect` until connection succeeds (not recommended)
2. Return a created client with its connection state set to `connecting`
3. Return `nil`, for no connection, and await a magic packet reply for further instantiation

Either party can finalise the creation of its client when receiving a P2P targetted magic packet:

```swift
func receiveMessage(
  _ text: String,
  metadata: Document,
  handle: P2PTransportFactoryHandle
) async throws -> P2PTransportClient? {
  ..
}
```

### Setup

To register a P2P connectivity option, simply provide the `p2pFactories` argument when instantiating the CypherMessenger.

```swift
let messenger = try await CypherMessenger.registerMessenger(
  username: "admin",
  authenticationMethod: .password("hunter2"),
  appPassword: ...,
  usingTransport: ....,
  p2pFactories: [
    IPv6TCPP2PTransportClientFactory(),
    MyCustomP2PTransportFactory()
  ],
  database: ...,
  eventHandler: ...
)
```

### Usage

You can attempt to establish a peer-to-peer session with members of a conversation:

```swift
let privateChat = try await chat.buildP2PConnections()
```

If a connection is created or disconnected, your EventHandler will be notified.

You list all currently open P2P connections in a chat using `chat.listOpenP2PConnections()`.
Or list all P2P connections globally using `messenger.listOpenP2PConnections()`

The connection is disconnected after becoming idle, manual closes or lost connectivity.
