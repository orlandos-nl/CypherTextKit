import XCTest
import CypherMessaging
import MessagingHelpers

final class ChatActivityPluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testPrivateChat() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                ChatActivityPlugin()
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
                ChatActivityPlugin()
            ]),
            on: eventLoop
        ).wait()
        
        let m0Chat = try m0.createPrivateChat(with: "m1").wait()
        XCTAssertNil(m0Chat.lastActivity)
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        XCTAssertNotNil(m0Chat.lastActivity)
        
        sleep(3)
        
        let m1Chat = try m1.getPrivateChat(with: "m0").wait()!
        XCTAssertNotNil(m1Chat.lastActivity)
    }
    
    func testGroupChat() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                ChatActivityPlugin()
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
                ChatActivityPlugin()
            ]),
            on: eventLoop
        ).wait()
        
        let m0Chat = try m0.createGroupChat(with: ["m1"]).wait()
        XCTAssertNil(m0Chat.lastActivity)
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        XCTAssertNotNil(m0Chat.lastActivity)
        
        sleep(3)
        
        let m1Chat = try m1.getGroupChat(byId: m0Chat.groupId).wait()!
        XCTAssertNotNil(m1Chat.lastActivity)
    }
}
