import BSON
import Crypto
import NIO
import XCTest
@testable import CypherMessaging
import CypherTransport
import CypherProtocol

final class CypherSDKTests: XCTestCase {
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
            delegate: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m1 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            delegate: SpoofCypherEventHandler(eventLoop: eventLoop),
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
            delegate: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m0d1 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            delegate: SpoofCypherEventHandler(eventLoop: eventLoop),
            on: eventLoop
        ).wait()
        
        let m1d0 = try CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            delegate: SpoofCypherEventHandler(eventLoop: eventLoop),
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
