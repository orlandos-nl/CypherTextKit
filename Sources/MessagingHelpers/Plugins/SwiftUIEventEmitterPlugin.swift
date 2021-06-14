//#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import CypherMessaging
import Combine

public final class SwiftUIEventEmitter: ObservableObject {
    public let onRekey = PassthroughSubject<Void, Never>()
    public let savedChatMessages = PassthroughSubject<AnyChatMessage, Never>()
//    public let onRekey = PassthroughSubject<Void, Never>()
    @Published public private(set) var conversations = [TargetConversation.Resolved]()
    @Published public fileprivate(set) var contacts = [Contact]()
    
    public init() {}
    
    public func boot(for messenger: CypherMessenger) async {
        do {
            self.conversations = try await messenger.listConversations(includingInternalConversation: true) { lhs, rhs in
                switch (lhs.lastActivity, rhs.lastActivity) {
                case (.some(let lhs), .some(let rhs)):
                    return lhs > rhs
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return true
                }
            }
            
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
        emitter.onRekey.send()
    }
    
    public func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {
        
    }
    
    public func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        nil
    }
    
    public func onSendMessage(
        _ message: SentMessageContext
    ) async throws -> SendMessageAction? {
        nil
    }
    
    public func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    public func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    
    public func onMessageChange(_ message: AnyChatMessage) { }
    public func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {
        emitter.contacts.append(contact)
    }
    public func onCreateConversation(_ conversation: AnyConversation) { }
    public func onCreateChatMessage(_ chatMessage: AnyChatMessage) {
        DispatchQueue.main.async {
            self.emitter.savedChatMessages.send(chatMessage)
        }
    }
    public func onContactIdentityChange(username: Username, messenger: CypherMessenger) { }
    public func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) { }
    public func onP2PClientClose(messenger: CypherMessenger) { }
}
//#endif
