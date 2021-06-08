import XCTest
import CypherMessaging
import MessagingHelpers

@available(macOS 12, *)
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

@available(macOS 12, *)
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
        ).get()
        
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
        ).get()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1").get()
        let m0Contact = try await m0.createContact(byUsername: "m1").get()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        let m1Chat = try await m1.getPrivateChat(with: "m0").get()!
        let m1Contact = try await m1.createContact(byUsername: "m0").get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 0)
        
        try await m0Contact.befriend().get()
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        XCTAssertFalse(m0Contact.mutualFriendship)
        XCTAssertFalse(m0Contact.contactBlocked)
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 2)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 0)
        
        XCTAssertFalse(m1Contact.mutualFriendship)
        XCTAssertFalse(m1Contact.contactBlocked)
        try await m1Contact.befriend().get()
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        XCTAssertTrue(m0Contact.mutualFriendship)
        XCTAssertTrue(m1Contact.mutualFriendship)
        XCTAssertFalse(m0Contact.contactBlocked)
        XCTAssertFalse(m1Contact.contactBlocked)
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        // Now they block each other
        try await m0Contact.block().get()
        
        XCTAssertFalse(m0Contact.mutualFriendship)
        XCTAssertTrue(m0Contact.contactBlocked)
        
        SpoofTransportClient.synchronize()
        
        XCTAssertFalse(m1Contact.mutualFriendship)
        XCTAssertTrue(m1Contact.contactBlocked)
        
        _ = try await m1Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 3)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 2)
        
        try await m1Contact.block().get()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 4)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 2)
        
        // And now they need to unblock to reclaim friendship
        
        try await m0Contact.unblock().get()
        try await m1Contact.unblock().get()
        
        SpoofTransportClient.synchronize()
        
        XCTAssertTrue(m0Contact.mutualFriendship)
        XCTAssertTrue(m1Contact.mutualFriendship)
        XCTAssertFalse(m0Contact.contactBlocked)
        XCTAssertFalse(m1Contact.contactBlocked)
        
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
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 6)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 4)
    }
    
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
        ).get()
        
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
        
        let m0GroupChat = try await m0.createGroupChat(with: ["m1"]).get()
        _ = try await m0GroupChat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        let m1GroupChat = try await m1.getGroupChat(byId: m0GroupChat.groupId).get()!
        
        try XCTAssertEqual(m1GroupChat.allMessages(sortedBy: .descending).wait().count, 1)
        try XCTAssertEqual(m1GroupChat.allMessages(sortedBy: .descending).wait().count, 1)
        
        let m1Contact = try await m1.createContact(byUsername: "m0").get()
        try await m1Contact.block().get()
        
        _ = try await m0Chat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        _ = try await m0GroupChat.sendRawMessage(
            type: .text,
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        try XCTAssertEqual(m0Chat.allMessages(sortedBy: .descending).wait().count, 2)
        try XCTAssertEqual(m1Chat.allMessages(sortedBy: .descending).wait().count, 1)
        
        try XCTAssertEqual(m0GroupChat.allMessages(sortedBy: .descending).wait().count, 2)
        try XCTAssertEqual(m1GroupChat.allMessages(sortedBy: .descending).wait().count, 1)
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
        ).get()
        
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
        ).get()
        
        let m0Chat = try await m0.createPrivateChat(with: "m1").get()
        let m0Contact = try await m0.createContact(byUsername: "m1").get()
        
        _ = try await m0Chat.sendRawMessage(
            type: .magic,
            messageSubtype: "custom-magic-packet",
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        XCTAssertEqual(inputCount, 0)
        let m1Contact = try await m1.createContact(byUsername: "m0").get()
        
        try await m0Contact.befriend().get()
        try await m1Contact.befriend().get()
        
        SpoofTransportClient.synchronize()
        
        _ = try await m0Chat.sendRawMessage(
            type: .magic,
            messageSubtype: "custom-magic-packet",
            text: "Hello",
            preferredPushType: .none
        ).get()
        
        SpoofTransportClient.synchronize()
        
        XCTAssertEqual(inputCount, 1)
        _ = m0
        _ = m1
    }
}
