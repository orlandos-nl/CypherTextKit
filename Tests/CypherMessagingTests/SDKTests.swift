import BSON
import Crypto
import NIO
import XCTest
import CypherMessaging
import SystemConfiguration
import CypherProtocol

final class CypherSDKTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testPrivateChatWithYourself() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        XCTAssertThrowsError(try m0.createPrivateChat(with: "m0").wait())
    }
    
    func testP2P() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try CypherMessenger.registerMessenger(
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
        ).wait()
        
        let m1 = try CypherMessenger.registerMessenger(
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
        ).wait()
        
        let m0Chat = try m0.createPrivateChat(with: "m1").wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        let m1Chat = try m1.getPrivateChat(with: "m0").wait()!
        
        sleep(1)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        _ = try m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(1)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 3)
        
        try m0Chat.buildP2PConnections().wait()
        
        sleep(1)
        
        try XCTAssertEqual(m0Chat.listOpenP2PConnections().wait().count, 1)
        try XCTAssertEqual(m1Chat.listOpenP2PConnections().wait().count, 1)
        
        let p2pConnection = try m1Chat.listOpenP2PConnections().wait()[0]
        XCTAssertEqual(p2pConnection.remoteStatus?.flags.contains(.isTyping), nil)
        
        for connection in try m0Chat.listOpenP2PConnections().wait() {
            try connection.updateStatus(flags: .isTyping).wait()
        }
        
        sleep(1)
        
        XCTAssertEqual(p2pConnection.remoteStatus?.flags.contains(.isTyping), true)
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
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m0_2 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m1 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m1_2 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m2 = try CypherMessenger.registerMessenger(
            username: "m2",
            authenticationMethod: .password("m2"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m3 = try CypherMessenger.registerMessenger(
            username: "m3",
            authenticationMethod: .password("m3"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m0Chat = try m0.createGroupChat(with: ["m1", "m2"]).wait()
        let groupId = GroupChatId(m0Chat.groupConfig.id)
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(5)
        
        let m0_2Chat = try m0_2.getGroupChat(byId: groupId).wait()!
        let m1Chat = try m1.getGroupChat(byId: groupId).wait()!
        let m1_2Chat = try m1_2.getGroupChat(byId: groupId).wait()!
        let m2Chat = try m2.getGroupChat(byId: groupId).wait()!
        XCTAssertNil(try m3.getGroupChat(byId: groupId).wait())
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m0_2Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1_2Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m2Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        _ = try m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        _ = try m2Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m0_2Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m1_2Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m2Chat.allMessages(sortedBy: .descending).wait().count, 4)
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
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m1 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m0Chat = try m0.createPrivateChat(with: "m1").wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(5)
        
        let m1Chat = try m1.getPrivateChat(with: "m0").wait()!
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        _ = try m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 3)
    }
    
    func testMultiDevicePrivateChat() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0d0 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m0d1 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m1d0 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        print("Clients setup - Starting interactions")
        
        let m0d1Chat = try m0d1.createPrivateChat(with: "m1").wait()
        
        _ = try m0d1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        let m0d0Chat = try m0d0.getPrivateChat(with: "m1").wait()!
        let m1d0Chat = try m1d0.getPrivateChat(with: "m0").wait()!
        
        sleep(2)
        
        try XCTAssertEqual(m0d0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m0d1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1d0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        _ = try m1d0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        _ = try m0d0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        try XCTAssertEqual(m0d0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m0d1Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1d0Chat.allMessages(sortedBy: .descending).wait().count, 3)
    }
}
