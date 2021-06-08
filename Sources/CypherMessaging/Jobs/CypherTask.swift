import CypherProtocol
import Foundation
import CryptoKit
import BSON
import NIO

enum _TaskKey: String, Codable {
    case sendMessage = "a"
    case processMessage = "b"
    case sendMultiRecipientMessage = "c"
    case processMultiRecipientMessage = "d"
    case sendMessageDeliveryStateChangeTask = "e"
    case receiveMessageDeliveryStateChangeTask = "f"
}

struct HandshakeMessageTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case pushType = "b"
        case recipient = "c"
        case localId = "d"
        case messageId = "e"
    }
    
    let message: RatchetedCypherMessage
    let pushType: PushType
    let recipient: Username
    let localId: UUID
    let messageId: String
}

@available(macOS 12, iOS 15, *)
struct CreateChatTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case pushType = "b"
        case recipient = "c"
        case localId = "e"
        case messageId = "f"
        case createdByMe = "g"
        case acceptedByOtherUser = "h"
    }
    
    let message: SingleCypherMessage
    let pushType: PushType
    let recipient: Username
    let localId: UUID
    let messageId: String
    let createdByMe: Bool
    let acceptedByOtherUser: Bool
}

@available(macOS 12, iOS 15, *)
struct AddContactTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case pushType = "b"
        case recipient = "c"
        case nickname = "d"
    }
    
    let message: SingleCypherMessage
    let pushType: PushType
    let recipient: Username
    let nickname: String
}

@available(macOS 12, iOS 15, *)
struct SendMessageTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case recipient = "b"
        case recipientDeviceId = "c"
        case localId = "e"
        case messageId = "f"
    }
    
    let message: CypherMessage
    let recipient: Username
    let recipientDeviceId: DeviceId
    let localId: UUID?
    let messageId: String
}

struct ReceiveMessageTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case messageId = "b"
        case sender = "c"
        case deviceId = "d"
    }
    
    let message: RatchetedCypherMessage
    let messageId: String
    let sender: Username
    let deviceId: DeviceId
}

@available(macOS 12, iOS 15, *)
struct SendMessageDeliveryStateChangeTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case localId = "a"
        case messageId = "b"
        case recipient = "c"
        case deviceId = "d"
        case newState = "e"
    }
    
    let localId: UUID
    let messageId: String
    let recipient: Username
    let deviceId: DeviceId?
    let newState: ChatMessageModel.DeliveryState
}

@available(macOS 12, iOS 15, *)
struct ReceiveMessageDeliveryStateChangeTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case messageId = "a"
        case sender = "b"
        case deviceId = "c"
        case newState = "d"
    }
    
    let messageId: String
    let sender: Username
    let deviceId: DeviceId?
    let newState: ChatMessageModel.DeliveryState
}

@available(macOS 12, iOS 15, *)
struct ReceiveMultiRecipientMessageTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case messageId = "b"
        case sender = "c"
        case deviceId = "d"
    }
    
    let message: MultiRecipientCypherMessage
    let messageId: String
    let sender: Username
    let deviceId: DeviceId
}

@available(macOS 12, iOS 15, *)
struct SendMultiRecipientMessageTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case message = "a"
        case messageId = "b"
        case recipients = "c"
        case localId = "d"
        case pushType = "e"
    }
    
    let message: CypherMessage
    let messageId: String
    let recipients: Set<Username>
    let localId: UUID?
    let pushType: PushType
}

enum GroupUserAction: Int, Codable {
    case invite = 0
    case remove = 1
    case promoteAdmin = 2
    case demoteAdmin = 3
}

struct GroupUserTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case user = "a"
        case group = "b"
        case action = "c"
    }
    
    let user: Username
    let group: GroupChatId
    let action: GroupUserAction
}

struct CreateGroupTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case name = "a"
        case participants = "b"
    }
    
    let name: String
    let participants: [Username]
}

struct ChangeGroupUsernameTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case user = "a"
        case group = "b"
        case nickname = "c"
    }
    
    let user: Username
    let group: GroupChatId
    let nickname: String
}

@available(macOS 12, iOS 15, *)
enum CypherTask: Codable, Task {
    private enum CodingKeys: String, CodingKey {
        case key = "a"
        case document = "b"
    }
    
    case sendMessage(SendMessageTask)
    case processMessage(ReceiveMessageTask)
    case sendMultiRecipientMessage(SendMultiRecipientMessageTask)
    case processMultiRecipientMessage(ReceiveMultiRecipientMessageTask)
    case sendMessageDeliveryStateChangeTask(SendMessageDeliveryStateChangeTask)
    case receiveMessageDeliveryStateChangeTask(ReceiveMessageDeliveryStateChangeTask)
    
    var retryMode: TaskRetryMode {
        switch self {
        case .sendMessage, .sendMultiRecipientMessage, .sendMessageDeliveryStateChangeTask:
            return .always
        case .processMultiRecipientMessage, .processMessage:
            return .never
        case .receiveMessageDeliveryStateChangeTask:
            return .retryAfter(60, maxAttempts: 5)
        }
    }
    
    var requiresConnectivity: Bool {
        switch self {
        case .sendMessage, .sendMultiRecipientMessage, .sendMessageDeliveryStateChangeTask:
            return true
        case .processMessage, .processMultiRecipientMessage, .receiveMessageDeliveryStateChangeTask:
            return false
        }
    }
    
    var priority: TaskPriority {
        switch self {
        case .processMessage, .sendMessage, .sendMultiRecipientMessage, .processMultiRecipientMessage:
            // These need to be fast, but are not urgent per-say
            return .higher
        case .sendMessageDeliveryStateChangeTask, .receiveMessageDeliveryStateChangeTask:
            // A conversation can continue without these, but it's preferred to be done sooner rather than later
            return .lower
        }
    }
    
    var isBackgroundTask: Bool {
        switch self {
        case .sendMessage, .processMessage, .sendMultiRecipientMessage, .processMultiRecipientMessage:
            return false
        case .receiveMessageDeliveryStateChangeTask, .sendMessageDeliveryStateChangeTask:
            // Both tasks can temporarily fail due to network or user delay
            return true
        }
    }
    
    var key: TaskKey {
        TaskKey(stringLiteral: _key.rawValue)
    }
    
    var _key: _TaskKey {
        switch self {
        case .sendMessage:
            return .sendMessage
        case .processMessage:
            return .processMessage
        case .sendMultiRecipientMessage:
            return .sendMultiRecipientMessage
        case .processMultiRecipientMessage:
            return .processMultiRecipientMessage
        case .sendMessageDeliveryStateChangeTask:
            return .sendMessageDeliveryStateChangeTask
        case .receiveMessageDeliveryStateChangeTask:
            return .receiveMessageDeliveryStateChangeTask
        }
    }
    
    func makeDocument() throws -> Document {
        switch self {
        case .sendMessage(let message):
            return try BSONEncoder().encode(message)
        case .processMessage(let message):
            return try BSONEncoder().encode(message)
        case .sendMultiRecipientMessage(let message):
            return try BSONEncoder().encode(message)
        case .processMultiRecipientMessage(let message):
            return try BSONEncoder().encode(message)
        case .sendMessageDeliveryStateChangeTask(let message):
            return try BSONEncoder().encode(message)
        case .receiveMessageDeliveryStateChangeTask(let message):
            return try BSONEncoder().encode(message)
        }
    }
    
    init(key: _TaskKey, document: Document) throws {
        let decoder = BSONDecoder()
        
        switch key {
        case .sendMessage:
            self = try .sendMessage(decoder.decode(SendMessageTask.self, from: document))
        case .processMessage:
            self = try .processMessage(decoder.decode(ReceiveMessageTask.self, from: document))
        case .sendMultiRecipientMessage:
            self = try .sendMultiRecipientMessage(decoder.decode(SendMultiRecipientMessageTask.self, from: document))
        case .processMultiRecipientMessage:
            self = try .processMultiRecipientMessage(decoder.decode(ReceiveMultiRecipientMessageTask.self, from: document))
        case .sendMessageDeliveryStateChangeTask:
            self = try .sendMessageDeliveryStateChangeTask(decoder.decode(SendMessageDeliveryStateChangeTask.self, from: document))
        case .receiveMessageDeliveryStateChangeTask:
            self = try .receiveMessageDeliveryStateChangeTask(decoder.decode(ReceiveMessageDeliveryStateChangeTask.self, from: document))
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        try self.init(
            key: container.decode(_TaskKey.self, forKey: .key),
            document: container.decode(Document.self, forKey: .document)
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(_key, forKey: .key)
        try container.encode(makeDocument(), forKey: .document)
    }
    
    func onDelayed(on messenger: CypherMessenger) -> EventLoopFuture<Void> {
        switch self {
        case .sendMessage(let task):
            return messenger._markMessage(byId: task.localId, as: .undelivered).map { _ in }
        case .sendMultiRecipientMessage(let task):
            return messenger._markMessage(byId: task.localId, as: .undelivered).map { _ in }
        case .processMessage, .processMultiRecipientMessage, .sendMessageDeliveryStateChangeTask, .receiveMessageDeliveryStateChangeTask:
            return messenger.eventLoop.makeSucceededVoidFuture()
        }
    }
    
    func execute(on messenger: CypherMessenger) -> EventLoopFuture<Void> {
        // TODO: After processing a message, emit a `received` event
        switch self {
        case .sendMessage(let message):
            debugLog("Sending message to \(message.recipient)")
            return TaskHelpers.writeMessageTask(task: message, messenger: messenger)
        case .processMessage(let message):
            debugLog("Processing message sent by \(message.sender)")
            return messenger._receiveMessage(
                message.message,
                multiRecipientContainer: nil,
                messageId: message.messageId,
                sender: message.sender,
                senderDevice: message.deviceId
            ).recover { error in
                debugLog("Error processing received message \(message.messageId) by \(message.sender) with error \(error)")
            }
        case .sendMultiRecipientMessage(let task):
            debugLog("Sending message to multiple recipients", task.recipients)
            return TaskHelpers.writeMultiRecipeintMessageTask(task: task, messenger: messenger)
        case .processMultiRecipientMessage(let task):
            return messenger._receiveMultiRecipientMessage(
                task.message,
                messageId: task.messageId,
                sender: task.sender,
                senderDevice: task.deviceId
            )
        case .sendMessageDeliveryStateChangeTask(let task):
            return messenger._markMessage(byId: task.localId, as: task.newState).flatMap { result in
                switch result {
                case .error:
                    return messenger.eventLoop.makeFailedFuture(CypherSDKError.invalidDeliveryStateTransition)
                case .success:
                    ()
                case .notModified:
                    () // Still emit the notification to the other side
                }
                
                switch task.newState {
                case .none, .undelivered:
                    return messenger.eventLoop.makeSucceededVoidFuture()
                case .read:
                    return messenger.transport.sendMessageReadReceipt(
                        byRemoteId: task.messageId,
                        to: task.recipient
                    )
                case .received:
                    return messenger.transport.sendMessageReceivedReceipt(
                        byRemoteId: task.messageId,
                        to: task.recipient
                    )
                case .revoked:
                    fatalError("TODO")
                }
            }.flatMapErrorThrowing { error in
                debugLog("Cannot modify delivery state for unknown message", error)
                throw error
            }
        case .receiveMessageDeliveryStateChangeTask(let task):
            return messenger._markMessage(byRemoteId: task.messageId, updatedBy: task.sender, as: task.newState)
                .map { _ in }
                .flatMapErrorThrowing { error in
                debugLog("Cannot modify delivery state for unknown message", error)
                throw error
            }
        }
    }
}

@available(macOS 12, iOS 15, *)
enum TaskHelpers {
    fileprivate static func writeMultiRecipeintMessageTask(
        task: SendMultiRecipientMessageTask,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Void> {
        guard messenger.authenticated == .authenticated else {
            debugLog("Not connected with the server")
            return messenger._markMessage(byId: task.localId, as: .undelivered).flatMapThrowing { _ in
                throw CypherSDKError.offline
            }
        }
        
        return messenger._fetchDeviceIdentities(forUsers: task.recipients).flatMap { devices in
            messenger._createMultiRecipientMessage(
                encrypting: task.message,
                forDevices: devices
            )
        }.flatMap { message in
            return messenger.transport.sendMultiRecipientMessage(message, messageId: task.messageId)
        }
    }

    fileprivate static func writeMessageTask(
        task: SendMessageTask,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Void> {
        guard messenger.authenticated == .authenticated else {
            debugLog("Not connected with the server")
            return messenger._markMessage(byId: task.localId, as: .undelivered).flatMapThrowing { _ in
                throw CypherSDKError.offline
            }
        }

        // Fetch the identity
        debugLog("Executing task: Send message")
        return messenger._writeWithRatchetEngine(ofUser: task.recipient, deviceId: task.recipientDeviceId) { ratchetEngine, rekeyState -> EventLoopFuture<Void> in
            do {
                let encodedMessage = try BSONEncoder().encode(task.message).makeData()
                let ratchetMessage = try ratchetEngine.ratchetEncrypt(encodedMessage)

                let encryptedMessage = try messenger._signRatchetMessage(ratchetMessage, rekey: rekeyState)

                return messenger.transport.sendMessage(
                    encryptedMessage,
                    toUser: task.recipient,
                    otherUserDeviceId: task.recipientDeviceId,
                    messageId: task.messageId
                )
            } catch {
                debugLog("Send message failed", error)
                return messenger.eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            messenger._markMessage(byId: task.localId, as: .none).map { _ in }
        }
    }
}
