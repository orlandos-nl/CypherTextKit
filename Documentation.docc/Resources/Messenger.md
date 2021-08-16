When your user first signs up for your app, they'll need to get access to the backend.

Your app can supply a registration screen, or the user can be provided the credentials in advance.

Once registration is completed, your app will need to create and register a `CypherMessenger` instance.

# Registering Users

```swift
let messenger = CypherMessenger.registerMessenger(
    username: Username("<unique identifier>"), // 1
    appPassword: "", // 2
    usingTransport: { request -> EventLoopFuture<VaporTransport> in
        // 3 - Create Transport Client
    },
    database: store, // 4
    eventHandler: myEventHandler // 5
)
```

If your product supports _anonymity_, make sure that the `username` is not relatable to a personal identity. It is preferred to use an identifier here, instead.

1. The `username` is commonly used to refer to another person and its devices. This is part of encrypted message contents, group chat communication and communication with the backend.
2. `appPassword` is used to encrypt the on-device database. If your app doesn't want or need this kind of encryption, you can simplify the user flow by providing a static password.
The Messenger's App Passwords can be changed at any time.
3. A closure is provided to create a TransportClient, a custom implementation that communicates with your backend/API. Any authentication is to be handled by the app itself.
4. Your app provides a datastore. Our example app for iOS uses an SQLite database. All data entering the data store is already encrypted.
5. An EventHandler is provided, which your app can use to process events such as incoming chat messages or state changes.

The messenger is created asynchronously. If you don't mind blocking the UI briefly, you can get the results immediately using `.wait()`

Please read [Transport](/docs/cyphertextkit/articles/transport) for more information about implementing a TransportClient.

# Starting the App

Upon launching the app, recreate the suspended CypherMessenger using the following code:

```swift
let messenger = CypherMessenger.resumeMessenger(
    appPassword: "",
    usingTransport: { request in
        // Create Transport Client
    },
    database: store,
    eventHandler: myEventHandler
)
```

If all the above is set up, you're ready to start messaging!