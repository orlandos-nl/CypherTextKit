**CypherTextKit** is a framework for establishing end-to-end encrypted communication between two users. It supports multiple devices per user, features encryption at rest and peer-to-peer networking. CypherTextKit currently targets iOS 15+ and macOS 12+, but can also run on Linux using Swift 5.5 or later.

The SDK is designed so that it can be easily implemented in existing communication apps. This allows you to re-use your existing iOS and backend code, but still provide a more secure and private communication experience.

[Read the Story](https://medium.com/@joannisorlandos/building-end-to-end-encrypted-ios-apps-4dd018a0290b)

### Transparent End-to-end Encryption

CypherTextKit aims to be a layer inbetween your existing messaging traffic and database storage. All encryption happens within the framework, relieving your client logic from the hard work and bugs that can occur. You can also leverage the framework for signing custom information or encrypted on-disk storage.

### Example Implementation

We provide an [Example Client](https://github.com/orlandos-nl/cyphertextkit-example) (iOS, macOS & CLI) as well as an [Example Server](https://github.com/orlandos-nl/CypherTextKitAPI). You can use these to start experimenting with CypherTextKit, or as an example for your own creations!

CypherTextKit demonstrates itself through a chat client, but it can also be applied to other communication. Think of the following examples:
- End-to-End Encrypted Email Clients
- Secret Messages over Printed QR Codes
- VOIP Communication

### Android & Windows

We've designed CypherTextKit based on Swift 5.5 using Server-Side Swift tools such as [SwiftNIO](https://github.com/apple/swift-nio) so that it can be ported to both Android and Windows. Any contributions or collaboration towards such an effort is welcome, and we're already planning it out.
