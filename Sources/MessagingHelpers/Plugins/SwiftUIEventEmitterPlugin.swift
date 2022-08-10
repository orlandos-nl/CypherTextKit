#if canImport(SwiftUI) && canImport(Combine) && (os(macOS) || os(iOS))
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
    public let userDevicesChanged = PassthroughSubject<Void, Never>()
    public let customConfigChanged = PassthroughSubject<Void, Never>()
    
    public let p2pClientConnected = PassthroughSubject<P2PClient, Never>()
    
    public let contactAdded = PassthroughSubject<Contact, Never>()
    public let conversationAdded = PassthroughSubject<AnyConversation, Never>()
    
    @Published public private(set) var conversations = [TargetConversation.Resolved]()
    @Published public fileprivate(set) var contacts = [Contact]()
    let sortChats: @MainActor @Sendable (TargetConversation.Resolved, TargetConversation.Resolved) -> Bool
    
    public init(sortChats: @escaping @Sendable @MainActor (TargetConversation.Resolved, TargetConversation.Resolved) -> Bool) {
        self.sortChats = sortChats
    }
    
    @MainActor public func boot(for messenger: CypherMessenger) async {
        do {
            self.conversations = try await messenger.listConversations(includingInternalConversation: true, increasingOrder: sortChats)
            self.contacts = try await messenger.listContacts()
            
            Task {
                while !messenger.isOnline {
                    try await Task.sleep(nanoseconds: NSEC_PER_SEC)
                }
                
                try await Task.sleep(nanoseconds: NSEC_PER_SEC)
                await messenger.resumeJobQueue()
            }
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
    
    public func onDeviceRegistery(_ deviceId: DeviceId, messenger: CypherMessenger) async throws {
        DispatchQueue.main.async {
            emitter.userDevicesChanged.send()
        }
    }
    
    public func onMessageChange(_ message: AnyChatMessage) {
        DispatchQueue.main.async {
            emitter.chatMessageChanged.send(message)
        }
    }
    
    public func onConversationChange(_ viewModel: AnyConversation) {
        Task.detached {
            let viewModel = await viewModel.resolveTarget()
            DispatchQueue.main.async {
                emitter.conversationChanged.send(viewModel)
            }
        }
    }
    
    public func onContactChange(_ contact: Contact) {
        emitter.contactChanged.send(contact)
    }
    
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {
        emitter.contacts.append(contact)
        emitter.contactAdded.send(contact)
    }
    
    public func onCreateConversation(_ viewModel: AnyConversation) {
        emitter.conversationAdded.send(viewModel)
    }
    
    public func onCreateChatMessage(_ chatMessage: AnyChatMessage) {
        self.emitter.savedChatMessages.send(chatMessage)
    }
    
    public func onRemoveContact(_ contact: Contact) {
        self.emitter.contacts.removeAll { $0.id == contact.id }
    }
    
    public func onRemoveChatMessage(_ message: AnyChatMessage) {
        self.emitter.chatMessageRemoved.send(message)
    }
    
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {
        emitter.p2pClientConnected.send(client)
    }
    
    public func onCustomConfigChange() {
        emitter.customConfigChanged.send()
    }
}
#endif
