Sending messages between two users happens within a **Conversation**.
Conversations are a sequence of communication, with a shared sequence for one or or more devices.

While communication often takes place between different users, they can occur between the devices of a single user as well.

Conversations are, based on the above definition, split into three groups:

1. Internal Conversations
2. Private Chats
3. Group Chats

You can list all conversations by running the following:

```swift
let allConversations = try messenger.listConversations(
    includingInternalConversation: true
) { lhs, rhs in
    // Sort the resultset, return `true` if lhs comes before rhs
    return true
}.wait()
```

### Sorting Conversations

By default, the conversation keeps little metadata about itself. There's a blank `metadata` property on each conversation model that can store information.
A common usecase is the implementation of a `lastActivity` timestamp inside the metadata container.

You could also sort conversations alphabetically, by their first name or username. Please note that first names are to be assigned locally, communicated via magic packets, or stored in unencrypted form on the server.

### Internal

An Internal Conversation exists solely within a single user's devices. It has exactly one member user, the subject.
This type of conversation can be used for a personal notebook, but could also function as a means for apps to synchronise information through **magic packets**.

You can get an instance of your User's internal conversation through the following code:

```swift
let conversation = try messenger.getInternalConversation().wait()
```

Each conversation also has an in-memory `Cache`, which can be used to store temporary metadata such as unread message counts.
Storing this data in temporarily reserves the principle of deriving data from a single persistent source.

Each conversation also has room for metadata, which can be modified in the hooks provided to the EventHandler

### Private Chats

Private Chats are conversations with exactly one other person.
With multi-device support, each of their registered devices will receive your messages.

You can list all existing private chats using `listPrivateChats(increasingOrder: )`, which allows you to define the sort method used to list the chats.

```swift
let otherUser: Username = ..

// Find Existing Chat
if let chat = try messenger.getPrivateChat(with: otherUser).wait() {
  // Use private chat
}

// Find or Create Chat
let chat = try messenger.createPrivateChat(with: otherUser).wait()
```

### Group Chats

Similar to Private Chats, you can get list group chats using `listGroupChats(increasingOrder: )`.

Rather than working with Usernames, Group Chats are read by their GroupId. Group

```swift
if let groupChat = try messenger.getGroupChat(byId: groupId).wait() else { 
  // Use group chat  
}
```

When creating a group chat however, you'll need to provide a Set of usernames that you'd like to invite.

```swift
let groupChat = try messenger.createGroupChat(with: [friend1, friend2])
```

This action will automatically start a session with all other participants.

During the creation of this group, you can provide two optional arguments.

1. **localMetadata**, which is stored on-device as part of the Conversation object.
2. **sharedMetadata**, which is added to the group config, and shared with other users.

```swift
let groupChat = try messenger.createGroupChat(
  with: [friend1, friend2],
  localMetadata: [
    "lastActivity": Date()
  ],
  sharedMetadata: [
    "groupName": "Best Friends"
  ]
)
```

### Sending Messages

You can send a message to other members of a chat using `conversation.sendRawMessage(..)` 
**sendRawMessage** allows you to send any form of message, including custom media or magic packets. 

CypherTextKit provides three major domains of messages;

1. **Text**; which is commonly represented as plaintext or markdown.
2. **Media**; for alternative user interactive content such as images, videos and files
3. **Magic**; which represents invisible / background packets. Magic packets are commonly _not_ saved on the client.

While transmitting a location, or editing a message, a magic packet may indicate this mutation in reference to a previous message sent by that user.
This system can be used for polls as well.

```swift
func sendRawMessage(
  type: CypherMessageType,
  messageSubtype: String? = nil,
  text: String,
  metadata: Document = [:],
  destructionTimer: TimeInterval? = nil,
  sentDate: Date = Date(),
  preferredPushType: PushType
) -> EventLoopFuture<AnyChatMessage?> {
```

The subtype can be used to represent the specific type of text, media, or magic packet. 
Please note that the `_/` prefix is reserved for CypherTextKit internal modules.

The metadata container can contain a variety of information, including binary blobs.

Finally, the `destructionTimer` and `preferredPushType` are two optional modules implemented by CypherTextKit.
They're implemented globally to ensure minimal complexity down the road.

### Reading Messages

Reading messages in a conversation can be done through two routes:

1. Listing all messages as an array
2. Iterating over a cursor

```swift
func allMessages(sortedBy sortMode: SortMode) -> EventLoopFuture<[AnyChatMessage]>
func cursor(sortedBy sortMode: SortMode) -> EventLoopFuture<AnyChatMessageCursor>
```

While listing all messages in an array is easy to do, it is extremely costly on performance.
Therefore we strongly recommend using the Cursor instead.

```swift
let cursor = try conversation.cursor(sortedBy: .descending).wait()
```

When reading messages from a cursor, simply read the next list using `cursor.getMore(50)`.

### Real-Time Messaging

Since conversations happen in real-time, it's important for new messages to show up in the UI.
The cursor will not emit any new messages in the existing conversation. To do so, use your EventHandler's `onCreateChatMessage` to react to these events.