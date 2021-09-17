Our example implementations come with a [Vapor](https://vapor.codes) based server, which implements all major CypherTextKit features.

It's highly recommended to use this server as a starting point for any new applications.
If you're adapting your existing backend for CypherTextKit however, there are a few features that are explained below.

### Server-Side Storage

When sending a message to another party, the server **must not** emit the same message twice.
Your server and client can implement an acknowledgement, in which case a message can rarely be received twice.
However, once a message is received it _should_ be removed from the server.

If a server decides to keep the message, it **must** mark it as received and block it from being sent in the future.

### Multi-Device Support

The single most critical step of adding multi-device support is keeping a separate backlog of messages per device.

### Multi-Recipient Messaging

When routing multi-recipient messages, your server must ensure a copy of this message arrives at each specified user/device.

As a recommended privacy measure, it's adviced to remove any keys from Multi-Recipient Messages that do not belong to the recipient device before sending.

### Certificate-Based Authentication

If possible, it's recommended to eliminate password-based authentication in favour of certficate-based authentication.

A good solution is to sign tokens with your device keys.

```swift
let signature = try messenger.sign(proof)
```

The server can verify this signature with the uploaded User's KeyBundle. The client sends its username and deviceId in the authentication request.
This method can be combined with a self-signed JWT, as demonstrated in the Vapor server.

By looking for the device config in the user's key bundle, the server can verify that the message was signed by that device.
This proves that the device was, in fact, authorised.

### Publishing Key Bundles

It's required to only allow publishing by devices whose identity matches that of a **master device**. The list of master devices is published in the user's key bundle.