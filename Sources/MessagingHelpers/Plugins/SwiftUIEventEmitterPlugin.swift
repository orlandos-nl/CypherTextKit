#if canImport(SwiftUI)
import SwiftUI
import CypherMessaging
import Combine

public final class SwiftUIEventEmitter: ObservableObject {
    public let onRekey = PassthroughSubject<Void, Never>()
    public let savedChatMessages = PassthroughSubject<AnyChatMessage, Never>()
    
    public let chatMessageChanged = PassthroughSubject<AnyChatMessage, Never>()
    public let chatMessageRemoved = PassthroughSubject<AnyChatMessage, Never>()
    public let conversationChanged = PassthroughSubject<TargetConversation.Resolved, Never>()
    public let contactChanged = PassthroughSubject<Contact, Never>()
    
    public let p2pClientConnected = PassthroughSubject<P2PClient, Never>()
    
    public let contactAdded = PassthroughSubject<Contact, Never>()
    public let conversationAdded = PassthroughSubject<AnyConversation, Never>()
    
    @Published public private(set) var conversations = [TargetConversation.Resolved]()
    @Published public fileprivate(set) var contacts = [Contact]()
    let sortChats: (TargetConversation.Resolved, TargetConversation.Resolved) -> Bool
    
    public init(sortChats: @escaping (TargetConversation.Resolved, TargetConversation.Resolved) -> Bool) {
        self.sortChats = sortChats
    }
    
    public func boot(for messenger: CypherMessenger) async {
        do {
            self.conversations = try await messenger.listConversations(includingInternalConversation: true, increasingOrder: sortChats)
            self.contacts = try await messenger.listContacts()
        } catch {}
    }
}

public struct SwiftUIEventEmitterPlugin: Plugin {
    let emitter: SwiftUIEventEmitter
    public static let pluginIdentifier = "@/emitter/swiftui"
    
    public init(emitter: SwiftUIEventEmitter) {
        self.emitter = emitter
    }
    
    public func onRekey(
        withUser username: Username,
        deviceId: DeviceId,
        messenger: CypherMessenger
    ) async throws {
        DispatchQueue.main.async {
            emitter.onRekey.send()
        }
    }
    
    public func onMessageChange(_ message: AnyChatMessage) {
        DispatchQueue.main.async {
            emitter.chatMessageChanged.send(message)
        }
    }
    
    public func onConversationChange(_ conversation: AnyConversation) {
        Task.detached {
            let conversation = await conversation.resolveTarget()
            DispatchQueue.main.async {
                emitter.conversationChanged.send(conversation)
            }
        }
    }
    
    public func onContactChange(_ contact: Contact) {
        DispatchQueue.main.async {
            emitter.contactChanged.send(contact)
        }
    }
    
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {
        DispatchQueue.main.async {
            emitter.contacts.append(contact)
            emitter.contactAdded.send(contact)
        }
    }
    
    public func onCreateConversation(_ conversation: AnyConversation) {
        DispatchQueue.main.async {
            emitter.conversationAdded.send(conversation)
        }
    }
    
    public func onCreateChatMessage(_ chatMessage: AnyChatMessage) {
        DispatchQueue.main.async {
            self.emitter.savedChatMessages.send(chatMessage)
        }
    }
    
    public func onRemoveContact(_ contact: Contact) {
        DispatchQueue.main.async {
            self.emitter.contacts.removeAll { $0.id == contact.id }
        }
    }
    
    public func onRemoveChatMessage(_ message: AnyChatMessage) {
        DispatchQueue.main.async {
            self.emitter.chatMessageRemoved.send(message)
        }
    }
    
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {
        DispatchQueue.main.async {
            emitter.p2pClientConnected.send(client)
        }
    }
}
#endif
