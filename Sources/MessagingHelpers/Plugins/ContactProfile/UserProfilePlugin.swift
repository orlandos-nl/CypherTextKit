import CypherMessaging
import NIO

public struct ContactMetadata: Codable {
    public fileprivate(set) var status: String?
    public fileprivate(set) var image: Data?
}

// TODO: Use synchronisation framework for own devices
// TODO: Select contacts to share the profile changes with
// TODO: Broadcast to a user that doesn't have a private chat
public struct UserProfilePlugin: Plugin {
    enum RekeyAction {
        case none, resetProfile
    }
    
    public static let pluginIdentifier = "@/contacts/profile"
    
    public init() {}
    
    public func onRekey(
        withUser username: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) -> EventLoopFuture<Void> {
        messenger.createContact(byUsername: username).flatMap { contact in
            contact.metadata[self.pluginIdentifier] = Document()
            return contact.save()
        }
    }
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?> {
        guard
            message.message.messageType == .magic,
            var subType = message.message.messageSubtype,
            subType.hasPrefix("@/contacts/profile/")
        else {
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        subType.removeFirst("@/contacts/profile/".count)
        let messenger = message.messenger
        let sender = message.sender.username
        
        switch subType {
        case "status/update":
            if sender == messenger.username {
                return messenger.modifyCustomConfig(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.status = message.message.text
                    return .ignore
                }
            }
            
            return messenger.createContact(byUsername: sender).flatMap { contact in
                contact.modifyMetadata(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.status = message.message.text
                    return .ignore
                }
            }
        case "picture/update":
            guard let imageBlob = message.message.metadata["blob"] as? Binary else {
                return messenger.eventLoop.makeSucceededFuture(.ignore)
            }
            
            let image = imageBlob.data
            
            if sender == messenger.username {
                return messenger.modifyCustomConfig(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.image = image
                    return .ignore
                }
            }
            
            return messenger.createContact(byUsername: sender).flatMap { contact in
                contact.modifyMetadata(
                    ofType: ContactMetadata.self,
                    forPlugin: Self.self
                ) { metadata in
                    metadata.image = image
                    return .ignore
                }
            }
        default:
            return messenger.eventLoop.makeSucceededFuture(.ignore)
        }
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) -> EventLoopFuture<SendMessageAction?> {
        guard
            message.message.messageType == .magic,
            let subType = message.message.messageSubtype,
            subType.hasPrefix("@/contacts/profile/")
        else {
            return message.messenger.eventLoop.makeSucceededFuture(nil)
        }
        
        return message.messenger.eventLoop.makeSucceededFuture(.send)
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) { }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ conversation: AnyChatMessage) { }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
}

extension Contact {
    public var status: String? {
        try? self.withMetadata(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { metadata in
            metadata.status
        }
    }
}

extension CypherMessenger {
    public func changeProfileStatus(
        to status: String
    ) -> EventLoopFuture<Void> {
        listContacts().flatMap { contacts in
            var done = contacts.map { contact in
                // TODO: Don't create private chat, but still emit change
                return self.createPrivateChat(with: contact.username).flatMap { chat in
                    chat.sendRawMessage(
                        type: .magic,
                        messageSubtype: "@/contacts/profile/status/update",
                        text: status,
                        preferredPushType: .none
                    )
                }
            }
            
            // TODO: Use synchronisation framework
            done.append(
                self.getInternalConversation().flatMap { chat in
                    chat.sendRawMessage(
                        type: .magic,
                        messageSubtype: "@/contacts/profile/status/update",
                        text: status,
                        preferredPushType: .none
                    )
                }
            )
            
            return EventLoopFuture.andAllSucceed(done, on: self.eventLoop)
        }.flatMap {
            self.modifyCustomConfig(
                ofType: ContactMetadata.self,
                forPlugin: UserProfilePlugin.self
            ) { metadata in
                metadata.status = status
            }
        }
    }
    
    public func changeProfilePicture(
        to data: Data
    ) -> EventLoopFuture<Void> {
        listContacts().flatMap { contacts in
            var done = contacts.map { contact in
                // TODO: Don't create private chat, but still emit change
                return self.createPrivateChat(with: contact.username).flatMap { chat in
                    chat.sendRawMessage(
                        type: .magic,
                        messageSubtype: "@/contacts/profile/status/update",
                        text: "",
                        metadata: [
                            "blob": data
                        ],
                        preferredPushType: .none
                    )
                }
            }
            
            // TODO: Use synchronisation framework
            done.append(
                self.getInternalConversation().flatMap { chat in
                    chat.sendRawMessage(
                        type: .magic,
                        messageSubtype: "@/contacts/profile/status/update",
                        text: "",
                        metadata: [
                            "blob": data
                        ],
                        preferredPushType: .none
                    )
                }
            )
            
            return EventLoopFuture.andAllSucceed(done, on: self.eventLoop)
        }.flatMap {
            self.modifyCustomConfig(
                ofType: ContactMetadata.self,
                forPlugin: UserProfilePlugin.self
            ) { metadata in
                metadata.image = data
            }
        }
    }
    
    public func readProfileMetadata() -> EventLoopFuture<ContactMetadata> {
        withCustomConfig(
            ofType: ContactMetadata.self,
            forPlugin: UserProfilePlugin.self
        ) { $0 }
    }
}
