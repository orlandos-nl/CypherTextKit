import BSON
import Crypto
import NIO
import XCTest
import CypherMessaging
import SystemConfiguration
import CypherProtocol

@available(macOS 10.15, iOS 13, *)
struct Synchronisation {
    let apps: [CypherMessenger]
    
    func synchronise() async throws {
        var hasWork = true
        
        repeat {
            hasWork = false
            if try await SpoofTransportClient.synchronize() == .synchronised {
                hasWork = true
            }
            
            for app in apps {
                if try await app.processJobQueue() == .synchronised {
                    hasWork = true
                }
            }
        } while hasWork
    }
}

func XCTAssertThrowsAsyncError<T>(_ run: @autoclosure () async throws -> T) async {
    do {
        _ = try await run()
        XCTFail("Expected test to throw error")
    } catch {}
}

func XCTAssertAsyncNil<T>(_ run: @autoclosure () async throws -> T?) async {
    do {
        let value = try await run()
        XCTAssertNil(value)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

func XCTAssertAsyncNotNil<T>(_ run: @autoclosure () async throws -> T?) async {
    do {
        let value = try await run()
        XCTAssertNotNil(value)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

func XCTAssertAsyncTrue(_ run: @autoclosure () async throws -> Bool) async {
    do {
        let value = try await run()
        XCTAssertTrue(value)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

func XCTAssertAsyncEqual<T: Equatable>(_ run: @autoclosure () async throws -> T, _ otherValue: T) async {
    do {
        let value = try await run()
        XCTAssertEqual(value, otherValue)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

@available(macOS 10.15, iOS 13, *)
final class CypherSDKTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testDisableMultiRecipientMessage() async throws {
        
    }
    
    func testPrivateChatWithYourself() async throws {
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        await XCTAssertThrowsAsyncError(try await m0.createPrivateChat(with: "m0"))
    }
    
    func testIPv6P2P() async throws {
        try await runP2PTests(IPv6TCPP2PTransportClientFactory())
    }
    
    func testInMemoryP2P() async throws {
        try await runP2PTests(SpoofP2PTransportFactory())
    }
    
    func runP2PTests<Factory: P2PTransportClientFactory>(_ factory: Factory) async throws {
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            p2pFactories: [
                factory
            ],
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            p2pFactories: [
                factory
            ],
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let sync = Synchronisation(apps: [m0, m1])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1")
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        let m1Chat = try await m1.getPrivateChat(with: "m0")!
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 1)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 3)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 3)
        
        try await m0Chat.buildP2PConnections()
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.listOpenP2PConnections().count, 1)
        await XCTAssertAsyncEqual(try await m1Chat.listOpenP2PConnections().count, 1)
        
        let p2pConnection = try await m1Chat.listOpenP2PConnections()[0]
        await XCTAssertAsyncEqual(p2pConnection.remoteStatus?.flags.contains(.isTyping), nil)
        
        for connection in try await m0Chat.listOpenP2PConnections() {
            try await connection.updateStatus(flags: .isTyping)
        }
        
        try await sync.synchronise()
        
        XCTAssertEqual(p2pConnection.remoteStatus?.flags.contains(.isTyping), true)
    }
    
    func testGroupChat() async throws {
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m0_2 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m1_2 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m2 = try await CypherMessenger.registerMessenger(
            username: "m2",
            authenticationMethod: .password("m2"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m3 = try await CypherMessenger.registerMessenger(
            username: "m3",
            authenticationMethod: .password("m3"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let sync = Synchronisation(apps: [m0, m1, m2, m3])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createGroupChat(with: ["m1", "m2"])
        let groupId = await m0Chat.getGroupId()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        let m0_2Chat = try await m0_2.getGroupChat(byId: groupId)!
        let m1Chat = try await m1.getGroupChat(byId: groupId)!
        let m1_2Chat = try await m1_2.getGroupChat(byId: groupId)!
        let m2Chat = try await m2.getGroupChat(byId: groupId)!
        await XCTAssertAsyncNil(try await m3.getGroupChat(byId: groupId))
        
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m0_2Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m1_2Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m2Chat.allMessages(sortedBy: .descending).count, 1)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        _ = try await m2Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 4)
        await XCTAssertAsyncEqual(try await m0_2Chat.allMessages(sortedBy: .descending).count, 4)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 4)
        await XCTAssertAsyncEqual(try await m1_2Chat.allMessages(sortedBy: .descending).count, 4)
        await XCTAssertAsyncEqual(try await m2Chat.allMessages(sortedBy: .descending).count, 4)
    }
    
    func testPrivateChat() async throws {
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let sync = Synchronisation(apps: [m0, m1])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1")
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        let m1Chat = try await m1.getPrivateChat(with: "m0")!
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 1)
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 3)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 3)
    }
    
    func testMultiDevicePrivateChatUnderLoad() async throws {
        struct DroppedPacket: Error {}
        actor Result {
            var droppedMessageIds = Set<String>()
            func addMessagedId(_ id: String) throws {
                if !droppedMessageIds.contains(id) {
                    droppedMessageIds.insert(id)
                    throw DroppedPacket()
                }
            }
        }
        let result = Result()
        // Always retry, because we don't want the test to take forever
        _CypherTaskConfig.sendMessageRetryMode = .always
        SpoofTransportClientSettings.shouldDropPacket = { username, type in
            switch type {
            case .readKeyBundle(username: let otherUser) where username == otherUser:
                ()
            case .deviceRegistery, .publishKeyBundle:
                ()
            case
                    .sendMessage(messageId: let id),
                    .readReceipt(remoteId: let id, otherUser: _),
                    .receiveReceipt(remoteId: let id, otherUser: _):
                // Cause as much chaos as possible
                try await result.addMessagedId(id)
            case .readKeyBundle, .publishBlob, .readBlob:
                if Bool.random() {
                    throw DroppedPacket()
                }
            }
        }
        defer {
            // Undo changes to CypherMessenger behaviour
            SpoofTransportClientSettings.shouldDropPacket = { _, _ in }
            _CypherTaskConfig.sendMessageRetryMode = nil
        }
        try await runTestMultiDevicePrivateChat(messageCount: 30)
    }
    
    func testMultiDevicePrivateChat() async throws {
        try await runTestMultiDevicePrivateChat(messageCount: 1)
    }
    
    func runTestMultiDevicePrivateChat(messageCount: Int) async throws {
        let m0d0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m0d1 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let m1d0 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(),
            eventHandler: SpoofCypherEventHandler()
        )
        
        let sync = Synchronisation(apps: [m0d0, m0d1, m1d0])
        try await sync.synchronise()
        
        await XCTAssertAsyncTrue(try await m0d0.isRegisteredOnline())
        await XCTAssertAsyncTrue(try await m0d1.isRegisteredOnline())
        await XCTAssertAsyncTrue(try await m1d0.isRegisteredOnline())
        
        print("Clients setup - Starting interactions")
        
        let m0d1Chat = try await m0d1.createPrivateChat(with: "m1")
        
        _ = try await m0d1Chat.sendRawMessage(
            type: .text,
            text: "M0D1 Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        guard let m0d0Chat = try await m0d0.getPrivateChat(with: "m1") else {
            XCTFail()
            return
        }
        
        guard let m1d0Chat = try await m1d0.getPrivateChat(with: "m0") else {
            XCTFail()
            return
        }
        
        print("Created chats")
        
        try await sync.synchronise()
        
        for i in 0..<messageCount {
            let base = 1 + (2 * i)
            await XCTAssertAsyncEqual(try await m0d0Chat.allMessages(sortedBy: .descending).count, base)
            await XCTAssertAsyncEqual(try await m0d1Chat.allMessages(sortedBy: .descending).count, base)
            await XCTAssertAsyncEqual(try await m1d0Chat.allMessages(sortedBy: .descending).count, base)
            
            _ = try await m1d0Chat.sendRawMessage(
                type: .text,
                text: "M1D0",
                preferredPushType: .none
            )
            
            try await sync.synchronise()
            
            _ = try await m0d0Chat.sendRawMessage(
                type: .text,
                text: "M0D0",
                preferredPushType: .none
            )
            
            try await sync.synchronise()
            
            await XCTAssertAsyncEqual(try await m0d0Chat.allMessages(sortedBy: .descending).count, base + 2)
            await XCTAssertAsyncEqual(try await m0d1Chat.allMessages(sortedBy: .descending).count, base + 2)
            await XCTAssertAsyncEqual(try await m1d0Chat.allMessages(sortedBy: .descending).count, base + 2)
        }
    }
}
