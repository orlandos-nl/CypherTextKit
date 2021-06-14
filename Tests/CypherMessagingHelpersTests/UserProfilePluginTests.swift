import XCTest
import CypherMessaging
import MessagingHelpers

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

func XCTAssertAsyncEqual<T: Equatable>(_ run: @autoclosure () async throws -> T, _ otherValue: T) async {
    do {
        let value = try await run()
        XCTAssertEqual(value, otherValue)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

func XCTAssertAsyncFalse(_ run: @autoclosure () async throws -> Bool) async {
    do {
        let value = try await run()
        XCTAssertFalse(value)
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

@available(macOS 12, iOS 15, *)
struct AcceptAllDeviceRegisteriesPlugin: Plugin {
    static let pluginIdentifier = "accept-all-device-registeries"
    
    func onRekey(withUser: Username, deviceId: DeviceId, messenger: CypherMessenger) async throws { }
    
    func onDeviceRegisteryRequest(_ config: UserDeviceConfig, messenger: CypherMessenger) async throws {
        try await messenger.addDevice(config)
    }
    
    func onReceiveMessage(_ message: ReceivedMessageContext) async throws -> ProcessMessageAction? { nil }
    func onSendMessage(_ message: SentMessageContext) async throws -> SendMessageAction? { nil }
    func createPrivateChatMetadata(withUser otherUser: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    func createContactMetadata(for username: Username, messenger: CypherMessenger) async throws -> Document { [:] }
    
    func onMessageChange(_ message: AnyChatMessage) {}
    func onCreateContact(_ contact: Contact, messenger: CypherMessenger) {}
    func onCreateConversation(_ conversation: AnyConversation) {}
    func onCreateChatMessage(_ conversation: AnyChatMessage) {}
    func onContactIdentityChange(username: Username, messenger: CypherMessenger) {}
    func onP2PClientOpen(_ client: P2PClient, messenger: CypherMessenger) {}
    func onP2PClientClose(messenger: CypherMessenger) {}
}

@available(macOS 12, iOS 15, *)
final class UserProfilePluginTests: XCTestCase {
    override func setUpWithError() throws {
        SpoofTransportClient.resetServer()
    }
    
    func testChangeStatus() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = elg.next()
        
        let m0 = try await CypherMessenger.registerMessenger(
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
        )
        
        let m0_2 = try await CypherMessenger.registerMessenger(
            username: "m0",
            authenticationMethod: .password("m0"),
            appPassword: "",
            usingTransport: SpoofTransportClient.self,
            database: MemoryCypherMessengerStore(eventLoop: eventLoop),
            eventHandler: PluginEventHandler(plugins: [
                UserProfilePlugin(),
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
                UserProfilePlugin()
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
        
        let contact = try await m1.getContact(byUsername: "m0")!
        
        XCTAssertNil(contact.status)
        await XCTAssertAsyncEqual(try await m0.readProfileMetadata().status, nil)
        await XCTAssertAsyncEqual(try await m0_2.readProfileMetadata().status, nil)
        
        try await m0.changeProfileStatus(to: "Available")
        
        try await sync.synchronise()
        
        XCTAssertEqual(contact.status, "Available")
        await XCTAssertAsyncEqual(try await m0.readProfileMetadata().status, "Available")
        await XCTAssertAsyncEqual(try await m0_2.readProfileMetadata().status, "Available")
    }
}
