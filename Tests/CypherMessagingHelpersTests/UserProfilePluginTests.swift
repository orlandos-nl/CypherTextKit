import XCTest
import CypherMessaging
import MessagingHelpers

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

final class UserProfilePluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testChangeStatus() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try CypherMessenger.registerMessenger(
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
        ).wait()
        
        let m0_2 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                UserProfilePlugin(),
            ]),
            on: eventLoop
        ).wait()
        
        let m1 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                UserProfilePlugin()
            ]),
            on: eventLoop
        ).wait()
        
        let m0Chat = try m0.createPrivateChat(with: "m1").wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(3)
        
        let m1Chat = try m1.getPrivateChat(with: "m0").wait()!
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        let contact = try m1.getContact(byUsername: "m0").wait()
        
        XCTAssertEqual(contact?.status, nil)
        XCTAssertEqual(try m0.readProfileMetadata().wait().status, nil)
        XCTAssertEqual(try m0_2.readProfileMetadata().wait().status, nil)
        
        try m0.changeProfileStatus(to: "Available").wait()
        
        sleep(2)
        
        XCTAssertEqual(contact?.status, "Available")
        XCTAssertEqual(try m0.readProfileMetadata().wait().status, "Available")
        XCTAssertEqual(try m0_2.readProfileMetadata().wait().status, "Available")
    }
}
