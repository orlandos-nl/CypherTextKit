import BSON
import Crypto
import NIO
import XCTest
import CypherMessaging
import SystemConfiguration
import CypherProtocol

@available(macOS 12, *)
final class CypherSDKTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testPrivateChatWithYourself() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        XCTAssertThrowsError(try m0.createPrivateChat(with: "m0").wait())
    }
    
    func testP2P() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            p2pFactories: [
                IPv6TCPP2PTransportClientFactory()
            ],
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            p2pFactories: [
                IPv6TCPP2PTransportClientFactory()
            ],
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
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
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 3)
        
        try await m0Chat.buildP2PConnections().get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.listOpenP2PConnections().wait().count, 1)
        try XCTAssertEqual(m1Chat.listOpenP2PConnections().wait().count, 1)
        
        let p2pConnection = try await m1Chat.listOpenP2PConnections().get()[0]
        XCTAssertEqual(p2pConnection.remoteStatus?.flags.contains(.isTyping), nil)
        
        for connection in try await m0Chat.listOpenP2PConnections().get() {
            try await connection.updateStatus(flags: .isTyping).get()
        }
        
        SpoofTransportClient.synchronize()
        
        XCTAssertEqual(p2pConnection.remoteStatus?.flags.contains(.isTyping), true)
    }
    
    func testGroupChat() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m0_2 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m1_2 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m2 = try await CypherMessenger.registerMessenger(
            username: "m2",
            authenticationMethod: .password("m2"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m3 = try await CypherMessenger.registerMessenger(
            username: "m3",
            authenticationMethod: .password("m3"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m0Chat = try await m0.createGroupChat(with: ["m1", "m2"]).get()
        let groupId = GroupChatId(m0Chat.groupConfig.id)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        let m0_2Chat = try await m0_2.getGroupChat(byId: groupId).get()!
        let m1Chat = try await m1.getGroupChat(byId: groupId).get()!
        let m1_2Chat = try await m1_2.getGroupChat(byId: groupId).get()!
        let m2Chat = try await m2.getGroupChat(byId: groupId).get()!
        XCTAssertNil(try m3.getGroupChat(byId: groupId).wait())
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m0_2Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1_2Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m2Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        _ = try await m2Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m0_2Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m1_2Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m2Chat.allMessages(sortedBy: .descending).wait().count, 4)
    }
    
    func testPrivateChat() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
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
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 3)
    }
    
    func testMultiDevicePrivateChat() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0d0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m0d1 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        let m1d0 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).get()
        
        print("Clients setup - Starting interactions")
        
        let m0d1Chat = try await m0d1.createPrivateChat(with: "m1").get()
        
        _ = try await m0d1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        let m0d0Chat = try await m0d0.getPrivateChat(with: "m1").get()!
        let m1d0Chat = try await m1d0.getPrivateChat(with: "m0").get()!
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0d0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m0d1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1d0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try await m1d0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        _ = try await m0d0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0d0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m0d1Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1d0Chat.allMessages(sortedBy: .descending).wait().count, 3)
    }
}
