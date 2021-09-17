# ``CypherTextKit``

CypherTextKit is a framework that provides end-to-end encrypted communication over existing transport layers.

The framework is designed for implementation in existing chat apps that supports private mesasging. CypherTextKit provdes extensibility for custom features, and even custom datastores with _encryption at rest_.

While CypherTextKit can be implemented with minimal backend support, some backend features are _highly recommended_.

## Features

**End-to-End Encryption**. We use a protocol based off the proven cryptographic standards made by Signal. CypherTextKit provides the powerful cryptography of Signal in a highly flexible and secure framework. Using CypherTextKit, your next chat app can be fast and secure too!

**Virtual Group Chats**. Our protocol supports group chats without server knowledge. This is one of the features that reduces metadata on the server.

**Custom Media Types**. Do you want to share images, contacts, files or videos? Our SDK can communicate all of the above and moe.

**Encryption at Rest**. The SDK is designed to support custom data stores. We provide a default implementation based on SQLite, but this can be swapped out with custom solutions. CypherTextKit will encrypt any data before it arrives in the datastore, and decrypts data after fetching it from the datastore.

**Voice & Video Callss**. Audio and video calls are part of the foundation of this SDK. Because the SDK itself is platform agnostic, the WebRTC library must be supplied by the client implementation. Our starter-kit app contains WebRTC based on Google's iOS framework.

**Read Receipts.** Know when your message has been received or seen using Read Receipts. Read Receipts are sent using an identifier known only to the two devices. No metadata can be correlated to a specific message.

## Backend

As part of the SDK, we provide a default backend- and client implementation. These implementations can be used as an example, or can be modified to suite end-user needs.

## Platform Support

CypherTextKit supports iOS, macOS and Linux on arm64 and x86_64 platforms. CypherTextKit is developer in- and for Swift environments. We're currently working on native SDKs for Android, Electron and Windows.

## Roadmap

**Peer to Peer Connections**. Typing Indicators, Read Receipts and Real-Time Communications will be more secure than ever before. Thanks to peer-to-peer connection support, your metadata won't even need to reach backend services. Peer-to-peer support is an optional module.

**Encrypted Push Notifications.** With Encrypted Push Notifications, notifications can contain the actual _encrypted_ message, so that a short preview can be shown in push notifications. All this, without sacrificing end-to-end encryption security.

**Background Communication.** Sharing your live-location with your family in the background, using a pre-shared key.

## Pricing

CypherTextKit is currently only supplied to custom orders. Please contact us via our contact form at [https://orlandos.nl/contact](https://orlandos.nl/contact).
