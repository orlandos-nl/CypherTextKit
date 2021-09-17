Contacts are any user your device is known to have communicated with.
Contacts may not be explicitly added by the user themselves, and may originate from a shared group chat.

You can attach metadata to contacts to differentiate their relation with you.

### List Contacts

List contacts using the `listContacts` API.

```swift
let contacts = try await messenger.listContacts()
```

Any filtering and sorting has to be done based on this call's results.
