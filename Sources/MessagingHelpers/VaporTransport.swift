import BSON
import Foundation
import CypherProtocol
import CypherMessaging
import JWTKit
import WebSocketKit

// TODO: Secondary servers

enum VaporTransportError: Error {
    case signUpFailed, usernameMismatch, sendMessageFailed
}

extension TransportCreationRequest: JWTAlgorithm {
    public var name: String { "ed25519" }
    
    public func sign<Plaintext>(_ plaintext: Plaintext) throws -> [UInt8] where Plaintext : DataProtocol {
        try Array(self.signature(for: plaintext))
    }
    
    public func verify<Signature, Plaintext>(_ signature: Signature, signs plaintext: Plaintext) throws -> Bool where Signature : DataProtocol, Plaintext : DataProtocol {
        // This implementation doesn't need to verify
        return false
    }
}

public struct UserDeviceId: Hashable, Codable {
    let user: Username
    let device: DeviceId
}

struct Token: JWTPayload {
    let device: UserDeviceId
    let exp: ExpirationClaim
    
    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
    }
}

//extension HTTPClient.Body {
//    static func bson<E: Encodable>(_ value: E) throws -> HTTPClient.Body {
//        return try .byteBuffer(BSONEncoder().encode(value).makeByteBuffer())
//    }
//}

public struct UserProfile: Decodable {
    public let username: String
    public let config: UserConfig
    public let blockedUsers: Set<String>
}

enum MessageType: String, Codable {
    case message = "a"
    case multiRecipientMessage = "b"
    case readReceipt = "c"
    case ack = "d"
}

struct DirectMessagePacket: Codable {
    let _id: ObjectId
    let messageId: String
    let createdAt: Date
    let sender: UserDeviceId
    let recipient: UserDeviceId
    let message: RatchetedCypherMessage
}

struct ChatMultiRecipientMessagePacket: Codable {
    let _id: ObjectId
    let messageId: String
    let createdAt: Date
    let sender: UserDeviceId
    let recipient: UserDeviceId
    let multiRecipientMessage: MultiRecipientCypherMessage
}

struct ReadReceiptPacket: Codable {
    enum State: Int, Codable {
        case received = 0
        case displayed = 1
    }
    
    let _id: ObjectId
    let messageId: String
    let state: State
    let sender: UserDeviceId
    let recipient: UserDeviceId
}

let maxBodySize = 500_000

@available(macOS 12, iOS 15, *)
extension URLSession {
    func getBSON<D: Decodable>(
        httpHost: String,
        url: String,
        username: Username,
        deviceId: DeviceId,
        token: String? = nil,
        as type: D.Type
    ) async throws -> D {
        var request = URLRequest(url: URL(string: "\(httpHost)/\(url)")!)
        request.httpMethod = "GET"
        request.addValue(username.raw, forHTTPHeaderField: "X-API-User")
        request.addValue(deviceId.raw, forHTTPHeaderField: "X-API-Device")
        if let token = token {
            request.addValue(token, forHTTPHeaderField: "X-API-Token")
        }
        let (data, _) = try await self.data(for: request)
        return try BSONDecoder().decode(type, from: Document(data: data))
    }
    
    func postBSON<E: Encodable>(
        httpHost: String,
        url: String,
        username: Username,
        deviceId: DeviceId,
        token: String? = nil,
        body: E
    )  async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "\(httpHost)/\(url)")!)
        request.httpMethod = "POST"
        request.addValue("application/bson", forHTTPHeaderField: "Content-Type")
        request.addValue(username.raw, forHTTPHeaderField: "X-API-User")
        request.addValue(deviceId.raw, forHTTPHeaderField: "X-API-Device")
        if let token = token {
            request.addValue(token, forHTTPHeaderField: "X-API-Token")
        }
        let data = try BSONEncoder().encode(body).makeData()
        
        if data.count > maxBodySize {
            return (Data(), URLResponse())
        }
        
        return try await self.upload(for: request, from: data)
    }
}

struct SIWARequest: Encodable {
    let username: String
    let appleToken: String
    let config: UserConfig
}

struct PlainSignUpRequest: Codable {
    let username: String
    let config: UserConfig
}

struct SignUpResponse: Codable {
    let existingUser: Username?
}

public struct SendMessage<Message: Codable>: Codable {
    let message: Message
    let pushType: PushType?
    let messageId: String
}

public struct SetToken: Codable {
    let token: String
}

public final class VaporTransport: CypherServerTransportClient {
    public let supportsMultiRecipientMessages = true
    
    public var delegate: CypherTransportClientDelegate?
    
    public func setDelegate(to delegate: CypherTransportClientDelegate) async throws {
        self.delegate = delegate
    }
    
    let eventLoop: EventLoop
    let username: Username
    let deviceId: DeviceId
    let httpClient: URLSession
    let host: String
    var httpHost: String { "https://\(host)" }
    var appleToken: String?
    private var wantsConnection = true
    private var webSocket: WebSocket?
    private(set) var signer: TransportCreationRequest
    
    private init(
        host: String,
        username: Username,
        deviceId: DeviceId,
        eventLoop: EventLoop,
        httpClient: URLSession,
        signer: TransportCreationRequest,
        appleToken: String?
    ) {
        self.host = host
        self.username = username
        self.deviceId = deviceId
        self.eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.httpClient = httpClient
        self.signer = signer
    }
    
    public static func login(for transportRequest: TransportCreationRequest, host: String, eventLoop: EventLoop) async throws -> VaporTransport {
        let client = URLSession(configuration: .default)
        return VaporTransport(
            host: host,
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            eventLoop: eventLoop,
            httpClient: client,
            signer: transportRequest,
            appleToken: nil
        )
    }
    
    public static func registerPlain(
        transportRequest: TransportCreationRequest,
        host: String,
        eventLoop: EventLoop
    ) async throws -> VaporTransport {
        let client = URLSession(configuration: .default)
        let request = PlainSignUpRequest(
            username: transportRequest.username.raw,
            config: transportRequest.userConfig
        )
        
        let transport = VaporTransport(
            host: host,
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            eventLoop: eventLoop,
            httpClient: client,
            signer: transportRequest,
            appleToken: nil
        )
        
        let (body, _) = try await client.postBSON(
            httpHost: transport.httpHost,
            url: "auth/plain/sign-up",
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            body: request
        )
            
        let signUpResponse = try BSONDecoder().decode(SignUpResponse.self, from: Document(data: body))
        
        if let existingUser = signUpResponse.existingUser, existingUser != transportRequest.username {
            throw VaporTransportError.usernameMismatch
        }
        
        return transport
    }
    
    public static func register(
        appleToken: String,
        transportRequest: TransportCreationRequest,
        host: String,
        eventLoop: EventLoop
    ) async throws -> VaporTransport {
        let client = URLSession(configuration: .default)
        let request = SIWARequest(
            username: transportRequest.username.raw,
            appleToken: appleToken,
            config: transportRequest.userConfig
        )
        let transport = VaporTransport(
            host: host,
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            eventLoop: eventLoop,
            httpClient: client,
            signer: transportRequest,
            appleToken: appleToken
        )
        
        let (body, _) = try await client.postBSON(
            httpHost: transport.httpHost,
            url: "auth/apple/sign-up",
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            body: request
        )
        
        let signUpResponse = try BSONDecoder().decode(SignUpResponse.self, from: Document(data: body))
        
        if let existingUser = signUpResponse.existingUser, existingUser != transportRequest.username {
            throw VaporTransportError.usernameMismatch
        }
        
        return transport
    }
    
    public private(set) var authenticated = AuthenticationState.unauthenticated
    
    private func makeToken() -> String? {
        return try? JWTSigner(algorithm: signer).sign(
            Token(
                device: UserDeviceId(
                    user: self.username,
                    device: self.deviceId
                ),
                exp: .init(value: Date().addingTimeInterval(3600))
            )
        )
    }
    
    public func disconnect() async {
        do {
            self.authenticated = .unauthenticated
            self.wantsConnection = false
            return try await (webSocket?.close() ?? eventLoop.makeSucceededVoidFuture()).get()
        } catch {}
    }
    
    public func reconnect() async {
        do {
            if authenticated == .authenticated {
                // Already connected
                return
            }
            
            wantsConnection = true
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/bson")
            headers.add(name: "X-API-User", value: username.raw)
            headers.add(name: "X-API-Device", value: deviceId.raw)
            if let token = makeToken() {
                headers.add(name: "X-API-Token", value: token)
            }
            
            let eventLoop = self.eventLoop
            
            try await WebSocket.connect(
                to: "wss://\(host)/websocket",
                headers: headers,
                configuration: .init(maxFrameSize: 512_000),
                on: eventLoop
            ) { webSocket in
                self.webSocket = webSocket
                self.authenticated = .authenticated
                
                webSocket.onBinary { [weak self] webSocket, buffer in
                    guard let delegate = self?.delegate, let transport = self else {
                        return
                    }
                    
                    struct Packet: Codable {
                        let id: ObjectId
                        let type: MessageType
                        let body: Document
                    }
                    
                    struct Ack: Codable {
                        let type: MessageType
                        let id: ObjectId
                        
                        init(id: ObjectId) {
                            self.id = id
                            self.type = .ack
                        }
                    }
                    
                    detach {
                        do {
                            let packet = try BSONDecoder().decode(Packet.self, from: Document(buffer: buffer))
                            
                            switch packet.type {
                            case .message:
                                let message = try BSONDecoder().decode(DirectMessagePacket.self, from: packet.body)
                                
                                try await delegate.receiveServerEvent(
                                    .messageSent(
                                        message.message,
                                        id: message.messageId,
                                        byUser: message.sender.user,
                                        deviceId: message.sender.device
                                    )
                                )
                            case .multiRecipientMessage:
                                let message = try BSONDecoder().decode(ChatMultiRecipientMessagePacket.self, from: packet.body)
                                
                                try await delegate.receiveServerEvent(
                                    .multiRecipientMessageSent(
                                        message.multiRecipientMessage,
                                        id: message.messageId,
                                        byUser: message.sender.user,
                                        deviceId: message.sender.device
                                    )
                                )
                            case .readReceipt:
                                let receipt = try BSONDecoder().decode(ReadReceiptPacket.self, from: packet.body)
                                
                                switch receipt.state {
                                case .displayed:
        //                            delegate.receiveServerEvent(.)
                                    ()
                                case .received:
        //                            delegate.receiveServerEvent(.messageReceived(by: receipt., deviceId: receipt.sender, id: receipt.messageId))
                                    ()
                                }
                            case .ack:
                                ()
                            }
                            
                            let ack = try BSONEncoder().encode(Ack(id: packet.id)).makeData()
                            webSocket.send(raw: ack, opcode: .binary)
                        } catch {
                            _ = await transport.disconnect()
                        }
                    }
                }
                
                webSocket.onClose.whenComplete { [weak self] _ in
                    if self?.wantsConnection == true {
                        _ = eventLoop.executeAsync {
                            await self?.reconnect()
                        }
                    }
                }
            }.get()
        } catch {
            print(error)
            self.authenticated = .authenticationFailure
            if self.wantsConnection {
                self.eventLoop.flatScheduleTask(in: .seconds(3)) {
                    self.eventLoop.executeAsync {
                        await self.reconnect()
                    }
                }
            }
        }
    }
    
    public func readKeyBundle(forUsername username: Username) async throws -> UserConfig {
        try await self.httpClient.getBSON(
            httpHost: httpHost,
            url: "users/\(username.raw)",
            username: self.username,
            deviceId: self.deviceId,
            token: self.makeToken(),
            as: UserProfile.self
        ).config
    }
    
    public func publishKeyBundle(_ data: UserConfig) async throws {
        _ = try await self.httpClient.postBSON(
            httpHost: httpHost,
            url: "current-user/config",
            username: self.username,
            deviceId: self.deviceId,
            token: self.makeToken(),
            body: data
        )
    }
    
    public func registerAPNSToken(_ token: Data) async throws {
        _ = try await self.httpClient.postBSON(
            httpHost: httpHost,
            url: "current-device/token",
            username: self.username,
            deviceId: self.deviceId,
            token: self.makeToken(),
            body: SetToken(token: token.hexString)
        )
    }
    
    public func sendMessageReadReceipt(byRemoteId remoteId: String, to username: Username) async throws { }
    
    public func sendMessageReceivedReceipt(byRemoteId remoteId: String, to username: Username) async throws { }
    
    public func requestDeviceRegistery(_ config: UserDeviceConfig) async throws {
        
    }
    
    public func publishBlob<C>(_ blob: C) async throws -> ReferencedBlob<C> where C : Decodable, C : Encodable {
        fatalError()
    }
    
    public func readPublishedBlob<C>(byId id: String, as type: C.Type) async throws -> ReferencedBlob<C>? where C : Decodable, C : Encodable {
        fatalError()
    }
    
    public func sendMessage(
        _ message: RatchetedCypherMessage,
        toUser username: Username,
        otherUserDeviceId deviceId: DeviceId,
        pushType: PushType,
        messageId: String
    ) async throws {
        _ = try await self.httpClient.postBSON(
            httpHost: httpHost,
            url: "users/\(username.raw)/devices/\(deviceId.raw)/send-message",
            username: self.username,
            deviceId: self.deviceId,
            token: self.makeToken(),
            body: SendMessage(
                message: message,
                pushType: pushType,
                messageId: messageId
            )
        )
    }
    
    public func sendMultiRecipientMessage(
        _ message: MultiRecipientCypherMessage,
        pushType: PushType,
        messageId: String
    ) async throws {
        _ = try await self.httpClient.postBSON(
            httpHost: httpHost,
            url: "actions/send-message",
            username: self.username,
            deviceId: self.deviceId,
            token: self.makeToken(),
            body: SendMessage(
                message: message,
                pushType: pushType,
                messageId: messageId
            )
        )
    }
}

let charA = UInt8(UnicodeScalar("a").value)
let char0 = UInt8(UnicodeScalar("0").value)

private func itoh(_ value: UInt8) -> UInt8 {
    return (value > 9) ? (charA + value - 10) : (char0 + value)
}

extension DataProtocol {
    var hexString: String {
        let hexLen = self.count * 2
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: hexLen)
        var offset = 0
        
        self.regions.forEach { (_) in
            for i in self {
                ptr[Int(offset * 2)] = itoh((i >> 4) & 0xF)
                ptr[Int(offset * 2 + 1)] = itoh(i & 0xF)
                offset += 1
            }
        }
        
        return String(bytesNoCopy: ptr, length: hexLen, encoding: .utf8, freeWhenDone: true)!
    }
}
