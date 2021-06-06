import XCTest
import CypherMessaging
import MessagingHelpers

struct CustomMagicPacketPlugin: Plugin {
    static let pluginIdentifier = "custom-magic-packet"
    let onInput: () -> ()
    let onOutput: () -> ()
    
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.eventLoop.makeSucceededVoidFuture()
    }
    
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) -> EventLoopFuture<Void> {
        messenger.addDevice(config)
    }
    
    func onReceiveMessage(_ message: ReceivedMessageContext) -> EventLoopFuture<ProcessMessageAction?> {
        if message.message.messageSubtype == "custom-magic-packet" {
            onInput()
        }
        
        return message.messenger.eventLoop.makeSucceededFuture(nil)
    }
    
    func onSendMessage(_ message: SentMessageContext) -> EventLoopFuture<SendMessageAction?> {
        if message.message.messageSubtype == "custom-magic-packet" {
            onOutput()
        }
        
        return message.messenger.eventLoop.makeSucceededFuture(nil)
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

final class FriendshipPluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testIgnoreUndecided() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        var ruleset = FriendshipRuleset()
        ruleset.ignoreWhenUndecided = true
        ruleset.blockAffectsGroupChats = false
        ruleset.canIgnoreMagicPackets = false
        ruleset.preventSendingDisallowedMessages = false
        
        let m0 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset)
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
                FriendshipPlugin(ruleset: ruleset)
            ]),
            on: eventLoop
        ).wait()
        
        let m0Chat = try m0.createPrivateChat(with: "m1").wait()
        let m0Contact = try m0.createContact(byUsername: "m1").wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(3)
        
        let m1Chat = try m1.getPrivateChat(with: "m0").wait()!
        let m1Contact = try m1.createContact(byUsername: "m0").wait()
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 0)
        
        try m0Contact.befriend().wait()
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        XCTAssertFalse(m0Contact.mutualFriendship)
        XCTAssertFalse(m0Contact.contactBlocked)
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 2)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 0)
        
        XCTAssertFalse(m1Contact.mutualFriendship)
        XCTAssertFalse(m1Contact.contactBlocked)
        try m1Contact.befriend().wait()
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        XCTAssertTrue(m0Contact.mutualFriendship)
        XCTAssertTrue(m1Contact.mutualFriendship)
        XCTAssertFalse(m0Contact.contactBlocked)
        XCTAssertFalse(m1Contact.contactBlocked)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        // Now they block each other
        try m0Contact.block().wait()
        
        XCTAssertFalse(m0Contact.mutualFriendship)
        XCTAssertTrue(m0Contact.contactBlocked)
        
        sleep(1)
        
        XCTAssertFalse(m1Contact.mutualFriendship)
        XCTAssertTrue(m1Contact.contactBlocked)
        
        _ = try m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 2)
        
        try m1Contact.block().wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(1)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 2)
        
        // And now they need to unblock to reclaim friendship
        
        try m0Contact.unblock().wait()
        try m1Contact.unblock().wait()
        
        sleep(1)
        
        XCTAssertTrue(m0Contact.mutualFriendship)
        XCTAssertTrue(m1Contact.mutualFriendship)
        XCTAssertFalse(m0Contact.contactBlocked)
        XCTAssertFalse(m1Contact.contactBlocked)
        
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
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 6)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 4)
    }
    
    func testBlockAffectsGroupChats() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        var ruleset = FriendshipRuleset()
        ruleset.ignoreWhenUndecided = false
        ruleset.blockAffectsGroupChats = true
        ruleset.canIgnoreMagicPackets = false
        ruleset.preventSendingDisallowedMessages = false
        
        let m0 = try CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                FriendshipPlugin(ruleset: ruleset)
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
                FriendshipPlugin(ruleset: ruleset)
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
        
        let m0GroupChat = try m0.createGroupChat(with: ["m1"]).wait()
        _ = try m0GroupChat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        let m1GroupChat = try m1.getGroupChat(byId: m0GroupChat.groupId).wait()!
        
        try XCTAssertEqual(m1GroupChat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1GroupChat.allMessages(sortedBy: .descending).wait().count, 1)
        
        let m1Contact = try m1.createContact(byUsername: "m0").wait()
        try m1Contact.block().wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        _ = try m0GroupChat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 2)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        try XCTAssertEqual(m0GroupChat.allMessages(sortedBy: .descending).wait().count, 2)
        try XCTAssertEqual(m1GroupChat.allMessages(sortedBy: .descending).wait().count, 1)
    }
    
    func testBlockingCanPreventOtherPlugins() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        var ruleset = FriendshipRuleset()
        ruleset.ignoreWhenUndecided = true
        ruleset.blockAffectsGroupChats = false
        ruleset.canIgnoreMagicPackets = true
        ruleset.preventSendingDisallowedMessages = false
        var inputCount = 0
        
        let m0 = try CypherMessenger.registerMessenger(
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
        ).wait()
        
        let m1 = try CypherMessenger.registerMessenger(
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
        ).wait()
        
        let m0Chat = try m0.createPrivateChat(with: "m1").wait()
        let m0Contact = try m0.createContact(byUsername: "m1").wait()
        
        _ = try m0Chat.sendRawMessage(
            type: .magic,
            messageSubtype: "custom-magic-packet",
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(3)
        
        XCTAssertEqual(inputCount, 0)
        let m1Contact = try m1.createContact(byUsername: "m0").wait()
        
        try m0Contact.befriend().wait()
        try m1Contact.befriend().wait()
        
        sleep(1)
        
        _ = try m0Chat.sendRawMessage(
            type: .magic,
            messageSubtype: "custom-magic-packet",
            text: "Hello",
            preferredPushType: .none
        ).wait()
        
        sleep(2)
        
        XCTAssertEqual(inputCount, 1)
        _ = m0
        _ = m1
    }
}
