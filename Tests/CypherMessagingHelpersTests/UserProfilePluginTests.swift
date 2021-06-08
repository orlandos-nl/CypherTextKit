import XCTest
import CypherMessaging
import MessagingHelpers

@available(macOS 12, *)
struct AcceptAllDeviceRegisteriesPlugin: Plugin {
    static let pluginIdentifier = "accept-all-device-registeries"
    
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.addDevice(config)
    }
    
    func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?> {
        message.messenger.eventLoop.makeSucceededFuture(nil)
    }
    
    func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction?> {
        message.messenger.eventLoop.makeSucceededFuture(nil)
    }
    
    func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    func createContactMetadata(for username: Username, messenger: CypherMessenger) -> EventLoopFuture<Document> {
        messenger.eventLoop.makeSucceededFuture([:])
    }
    
    func onMessageChange(_ message: AnyChatMessage) {}
    func onCreateContact(_ contact: DecryptedModel<ContactModel>, messenger: CypherMessenger) {}
    func onCreateConversation(_ conversation: AnyConversation) {}
    func onCreateChatMessage(_ conversation: AnyChatMessage) {}
    func onContactIdentityChange(username: Username, messenger: CypherMessenger) {}
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {}
    func onP2PClientClose(messenger: CypherMessenger) {}
}

@available(macOS 12, *)
final class UserProfilePluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testChangeStatus() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                UserProfilePlugin(),
                AcceptAllDeviceRegisteriesPlugin()
            ]),
            on: eventLoop
        ).get()
        
        let m0_2 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                UserProfilePlugin(),
            ]),
            on: eventLoop
        ).get()
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                UserProfilePlugin()
            ]),
            on: eventLoop
        ).get()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1").get()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        let m1Chat = try await m1.getPrivateChat(with: "m0").get()!
        
        SpoofTransportClient.synchronize()
        
        try  XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        let contact = try await m1.getContact(byUsername: "m0").get()
        
        XCTAssertEqual(contact?.status, nil)
        XCTAssertEqual(try m0.readProfileMetadata().wait().status, nil)
        XCTAssertEqual(try m0_2.readProfileMetadata().wait().status, nil)
        
        try await m0.changeProfileStatus(to: "Available").get()
        
        SpoofTransportClient.synchronize()
        
        XCTAssertEqual(contact?.status, "Available")
        XCTAssertEqual(try m0.readProfileMetadata().wait().status, "Available")
        XCTAssertEqual(try m0_2.readProfileMetadata().wait().status, "Available")
    }
}
