import XCTest
import CypherMessaging
import MessagingHelpers

@available(macOS 12, iOS 15, *)
final class ChatActivityPluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testPrivateChat() async throws {
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: PluginEventHandler(plugins: [
                ChatActivityPlugin()
            ])
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: PluginEventHandler(plugins: [
                ChatActivityPlugin()
            ])
        )
        let sync = Synchronisation(apps: [m0, m1])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1")
        XCTAssertNil(m0Chat.lastActivity)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        XCTAssertNotNil(m0Chat.lastActivity)
        
        
        try await sync.synchronise()
        
        let m1Chat = try await m1.getPrivateChat(with: "m0")!
        XCTAssertNotNil(m1Chat.lastActivity)
    }
    
    func testGroupChat() async throws {
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: PluginEventHandler(plugins: [
                ChatActivityPlugin()
            ])
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: PluginEventHandler(plugins: [
                ChatActivityPlugin()
            ])
        )
        
        let sync = Synchronisation(apps: [m0, m1])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createGroupChat(with: ["m1"])
        XCTAssertNil(m0Chat.lastActivity)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .ascending).count, 1)
        XCTAssertNotNil(m0Chat.lastActivity)
        
        try await sync.synchronise()
        
        if let m1Chat = try await m1.getGroupChat(byId: m0Chat.getGroupId()) {
            await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .ascending).count, 1)
            XCTAssertNotNil(m1Chat.lastActivity)
        } else {
            XCTFail()
        }
    }
}
