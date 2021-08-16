import XCTest
import CypherMessaging
import MessagingHelpers

@available(macOS 12, iOS 15, *)
struct Synchronisation {
    let apps: [CypherMessenger]
    
    func synchronise() async throws {
        var hasWork = 5
        
        repeat {
            hasWork -= 1
            if try await SpoofTransportClient.synchronize() != .skipped {
                hasWork = 10
            }
            
            for app in apps {
                if try await app.processJobQueue() != .skipped {
                    hasWork = 10
                }
            }
        } while hasWork > 0
    }
}

@available(macOS 12, iOS 15, *)
struct CustomMagicPacketPlugin: Plugin {
    static let pluginIdentifier = "custom-magic-packet"
    let onInput: () -> ()
    let onOutput: () -> ()
    
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {
        try await messenger.addDevice(config)
    }
    
    func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? {
        if message.message.messageSubtype == "custom-magic-packet" {
            onInput()
        }
        
        return nil
    }
    
    func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction? {
        if message.message.messageSubtype == "custom-magic-packet" {
            onOutput()
        }
        
        return nil
    }
}

@available(macOS 12, iOS 15, *)
final class FriendshipPluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testIgnoreUndecided() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        var ruleset = FriendshipRuleset()
        ruleset.ignoreWhenUndecided = true
        ruleset.blockAffectsGroupChats = false
        ruleset.canIgnoreMagicPackets = false
        ruleset.preventSendingDisallowedMessages = false
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset)
            ]),
            on: eventLoop
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset)
            ]),
            on: eventLoop
        )
        
        let sync = Synchronisation(apps: [m0, m1])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1")
        let m0Contact = try await m0.createContact(byUsername: "m1")
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        let m1Chat = try await m1.getPrivateChat(with: "m0")!
        let m1Contact = try await m1.createContact(byUsername: "m0")
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 0)
        
        try await m0Contact.befriend()
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        XCTAssertFalse(m0Contact.isMutualFriendship)
        XCTAssertFalse(m0Contact.isBlocked)
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 2)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 0)
        
        XCTAssertFalse(m1Contact.isMutualFriendship)
        XCTAssertFalse(m1Contact.isBlocked)
        
        try await m1Contact.befriend()
        try await sync.synchronise()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        XCTAssertTrue(m0Contact.isMutualFriendship)
        XCTAssertTrue(m1Contact.isMutualFriendship)
        XCTAssertFalse(m0Contact.isBlocked)
        XCTAssertFalse(m1Contact.isBlocked)
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 3)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 1)
        
        // Now they block each other
        try await m0Contact.block()
        
        XCTAssertFalse(m0Contact.isMutualFriendship)
        XCTAssertTrue(m0Contact.isBlocked)
        
        try await sync.synchronise()
        
        XCTAssertFalse(m1Contact.isMutualFriendship)
        XCTAssertTrue(m1Contact.isBlocked)
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 3)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 2)
        
        try await m1Contact.block()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 4)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 2)
        
        // And now they need to unblock to reclaim friendship
        
        try await m0Contact.unblock()
        try await m1Contact.unblock()
        
        try await sync.synchronise()
        
        XCTAssertTrue(m0Contact.isMutualFriendship)
        XCTAssertTrue(m1Contact.isMutualFriendship)
        XCTAssertFalse(m0Contact.isBlocked)
        XCTAssertFalse(m1Contact.isBlocked)
        
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
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 6)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 4)
    }
    
    //    func testHeavyLoad() async throws {
    //        let el = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
    //        let m0 = try await CypherMessenger.registerMessenger(
    //            username: "m0",
    //            appPassword: "",
    //            usingTransport: { request in
    //            try await VaporTransport.registerPlain(transportRequest: request, eventLoop: el)
    //            },
    //            database: MemoryCypherMessengerStore(eventLoop: el),
    //            eventHandler: SpoofCypherEventHandler(),
    //            on: el
    //        )
    //        
    //        let m1 = try await CypherMessenger.registerMessenger(
    //            username: "m1",
    //            appPassword: "",
    //            usingTransport: { request in
    //                try await VaporTransport.registerPlain(transportRequest: request, eventLoop: el)
    //            },
    //            database: MemoryCypherMessengerStore(eventLoop: el),
    //            eventHandler: SpoofCypherEventHandler(),
    //            on: el
    //        )
    //        
    //        try el.executeAsync {
    //            let chat = try await m0.createPrivateChat(with: "m1")
    //            
    //            for _ in 0..<1000 {
    //                _ = el.executeAsync {
    //                    _ = try await chat.sendRawMessage(type: .text, text: "Hello", preferredPushType: .none)
    //                }
    //            }
    //        }.wait()
    //        
    //        var receivedAll = false
    //        repeat {
    //            sleep(1)
    //            if let chat = try await m1.getPrivateChat(with: "m0") {
    //                let count = try await chat.allMessages(sortedBy: .ascending).count
    //                receivedAll = count >= 1000
    //                print("Processed \(count)")
    //            }
    //        } while !receivedAll
    //    }
    
    func testBlockAffectsGroupChats() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        var ruleset = FriendshipRuleset()
        ruleset.ignoreWhenUndecided = false
        ruleset.blockAffectsGroupChats = true
        ruleset.canIgnoreMagicPackets = false
        ruleset.preventSendingDisallowedMessages = false
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset)
            ]),
            on: eventLoop
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset)
            ]),
            on: eventLoop
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
        
        let m0GroupChat = try await m0.createGroupChat(with: ["m1"])
        _ = try await m0GroupChat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        guard let m1GroupChat = try await m1.getGroupChat(byId: m0GroupChat.getGroupId()) else {
            return
        }
        
        await XCTAssertAsyncEqual(try await m1GroupChat.allMessages(sortedBy: .descending).count, 1)
        await XCTAssertAsyncEqual(try await m1GroupChat.allMessages(sortedBy: .descending).count, 1)
        
        let m1Contact = try await m1.createContact(byUsername: "m0")
        try await m1Contact.block()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        _ = try await m0GroupChat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        )
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(try await m0Chat.allMessages(sortedBy: .descending).count, 2)
        await XCTAssertAsyncEqual(try await m1Chat.allMessages(sortedBy: .descending).count, 1)
        
        await XCTAssertAsyncEqual(try await m0GroupChat.allMessages(sortedBy: .descending).count, 2)
        await XCTAssertAsyncEqual(try await m1GroupChat.allMessages(sortedBy: .descending).count, 1)
    }
    
    func testBlockingCanPreventOtherPlugins() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        var ruleset = FriendshipRuleset()
        ruleset.ignoreWhenUndecided = true
        ruleset.blockAffectsGroupChats = false
        ruleset.canIgnoreMagicPackets = true
        ruleset.preventSendingDisallowedMessages = false
        var inputCount = 0
        
        let m0 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset),
                CustomMagicPacketPlugin(onInput: {
            inputCount += 1
        }, onOutput: {})
            ]),
            on: eventLoop
        )
        
        let m1 = try await CypherMessenger.registerMessenger(
            username: "m1",
            authenticationMethod: .password("m1"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset),
                CustomMagicPacketPlugin(onInput: {
            inputCount += 1
        }, onOutput: {})
            ]),
            on: eventLoop
        )
        
        let sync = Synchronisation(apps: [m0, m1])
        try await sync.synchronise()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1")
        let m0Contact = try await m0.createContact(byUsername: "m1")
        
        _ = try await m0Chat.sendRawMessage(
            type: .magic,
            messageSubtype: "custom-magic-packet",
            text: "Hello",
            preferredPushType: .none
        )
        
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(inputCount, 0)
        let m1Contact = try await m1.createContact(byUsername: "m0")
        
        try await m0Contact.befriend()
        try await m1Contact.befriend()
        
        
        try await sync.synchronise()
        
        _ = try await m0Chat.sendRawMessage(
            type: .magic,
            messageSubtype: "custom-magic-packet",
            text: "Hello",
            preferredPushType: .none
        )
        
        
        try await sync.synchronise()
        
        await XCTAssertAsyncEqual(inputCount, 1)
        _ = m0
        _ = m1
    }
}
