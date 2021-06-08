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
    case readReceipt = "b"
}

struct ChatMessagePacket: Codable {
    let _id: ObjectId
    let messageId: String
    let createdAt: Date
    let sender: UserDeviceId
    let recipient: UserDeviceId
    let message: MultiRecipientCypherMessage
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

let host = "localhost:8080"
let httpHost = "http://\(host)"

@available(macOS 12, iOS 15, *)
extension URLSession {
    func getBSON<D: Decodable>(
        url: String,
        username: Username,
        deviceId: DeviceId,
        token: String? = nil,
        as type: D.Type
    ) async throws -> D {
        var request = URLRequest(url: URL(string: "\(httpHost)/\(url)")!)
        request.httpMethod = "GET"
        request.addValue("application/bson", forHTTPHeaderField: "Content-Type")
        request.addValue(username.raw, forHTTPHeaderField: "X-API-User")
        request.addValue(deviceId.raw, forHTTPHeaderField: "X-API-Device")
        if let token = token {
            request.addValue(token, forHTTPHeaderField: "X-API-Token")
        }
        let (data, _) = try await self.data(for: request)
        return try BSONDecoder().decode(type, from: Document(data: data))
    }
    
    func postBSON<E: Encodable>(
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

public struct SendMessage: Codable {
    let message: MultiRecipientCypherMessage
    let messageId: String
}

public final class VaporTransport: CypherServerTransportClient {
    public let supportsMultiRecipientMessages = true
    
    public var delegate: CypherTransportClientDelegate?
    
    let eventLoop: EventLoop
    let username: Username
    let deviceId: DeviceId
    let httpClient: URLSession
    var appleToken: String?
    private var wantsConnection = true
    private var webSocket: WebSocket?
    private(set) var signer: TransportCreationRequest
    
    private init(
        username: Username,
        deviceId: DeviceId,
        eventLoop: EventLoop,
        httpClient: URLSession,
        signer: TransportCreationRequest,
        appleToken: String?
    ) {
        self.username = username
        self.deviceId = deviceId
        self.eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.httpClient = httpClient
        self.signer = signer
    }
    
    public static func login(for transportRequest: TransportCreationRequest, eventLoop: EventLoop) -> EventLoopFuture<VaporTransport> {
        let client = URLSession(configuration: .default)
        let transport = VaporTransport(
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            eventLoop: eventLoop,
            httpClient: client,
            signer: transportRequest,
            appleToken: nil
        )
        
        return eventLoop.makeSucceededFuture(transport)
    }
    
    public static func registerPlain(
        transportRequest: TransportCreationRequest,
        eventLoop: EventLoop
    ) async throws -> VaporTransport {
        let client = URLSession(configuration: .default)
        let request = PlainSignUpRequest(
            username: transportRequest.username.raw,
            config: transportRequest.userConfig
        )
        
        let (body, _) = try await client.postBSON(
            url: "auth/plain/sign-up",
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            body: request
        )
            
        let signUpResponse = try BSONDecoder().decode(SignUpResponse.self, from: Document(data: body))
        
        if let existingUser = signUpResponse.existingUser, existingUser != transportRequest.username {
            throw VaporTransportError.usernameMismatch
        }
        
        return VaporTransport(
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            eventLoop: eventLoop,
            httpClient: client,
            signer: transportRequest,
            appleToken: nil
        )
    }
    
    public static func register(
        appleToken: String,
        transportRequest: TransportCreationRequest,
        eventLoop: EventLoop
    ) async throws -> VaporTransport {
        let client = URLSession(configuration: .default)
        let request = SIWARequest(
            username: transportRequest.username.raw,
            appleToken: appleToken,
            config: transportRequest.userConfig
        )
        
        let (body, _) = try await client.postBSON(
            url: "auth/apple/sign-up",
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            body: request
        )
        
        let signUpResponse = try BSONDecoder().decode(SignUpResponse.self, from: Document(data: body))
        
        if let existingUser = signUpResponse.existingUser, existingUser != transportRequest.username {
            throw VaporTransportError.usernameMismatch
        }
        
        return VaporTransport(
            username: transportRequest.username,
            deviceId: transportRequest.deviceId,
            eventLoop: eventLoop,
            httpClient: client,
            signer: transportRequest,
            appleToken: appleToken
        )
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
    
    @discardableResult
    public func disconnect() -> EventLoopFuture<Void> {
        self.authenticated = .unauthenticated
        self.wantsConnection = false
        return webSocket?.close() ?? eventLoop.makeSucceededVoidFuture()
    }
    
    @discardableResult
    public func reconnect() -> EventLoopFuture<Void> {
        wantsConnection = true
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/bson")
        headers.add(name: "X-API-User", value: username.raw)
        headers.add(name: "X-API-Device", value: deviceId.raw)
        if let token = makeToken() {
            headers.add(name: "X-API-Token", value: token)
        }
        
        return WebSocket.connect(to: "ws://\(host)/websocket", headers: headers, on: eventLoop) { webSocket in
            self.webSocket = webSocket
            self.authenticated = .authenticated
            
            webSocket.onBinary { [weak self] webSocket, buffer in
                guard let delegate = self?.delegate else {
                    return
                }
                
                struct Packet: Codable {
                    let type: MessageType
                    let body: Document
                }
                
                do {
                    let packet = try BSONDecoder().decode(Packet.self, from: Document(buffer: buffer))
                    
                    switch packet.type {
                    case .message:
                        let message = try BSONDecoder().decode(ChatMessagePacket.self, from: packet.body)
                        
                        _ = delegate.receiveServerEvent(
                            .multiRecipientMessageSent(
                                message.message,
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
                    }
                } catch {
                    _ = self?.disconnect()
                }
            }
            
            webSocket.onClose.whenComplete { [weak self] _ in
                if self?.wantsConnection == true {
                    self?.reconnect()
                }
            }
        }.flatMapErrorThrowing { error in
            if self.wantsConnection {
                self.eventLoop.scheduleTask(in: .seconds(3)) {
                    self.reconnect()
                }
            }
            
            self.authenticated = .authenticationFailure
            throw error
        }
    }
    
    public func sendMessageReadReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void> {
        eventLoop.makeSucceededVoidFuture()
    }
    
    public func sendMessageReceivedReceipt(byRemoteId remoteId: String, to username: Username) -> EventLoopFuture<Void> {
        eventLoop.makeSucceededVoidFuture()
    }
    
    public func requestDeviceRegistery(_ config: UserDeviceConfig) -> EventLoopFuture<Void> {
        fatalError("Unsupported through server")
    }
    
    public func readKeyBundle(forUsername username: Username) -> EventLoopFuture<UserConfig> {
        eventLoop.executeAsync {
            try await self.httpClient.getBSON(
                url: "users/\(username.raw)",
                username: self.username,
                deviceId: self.deviceId,
                token: self.makeToken(),
                as: UserProfile.self
            ).config
        }
    }
    
    public func publishKeyBundle(_ data: UserConfig) -> EventLoopFuture<Void> {
        eventLoop.executeAsync {
            _ = try await self.httpClient.postBSON(
                url: "current-user/config",
                username: self.username,
                deviceId: self.deviceId,
                token: self.makeToken(),
                body: data
            )
        }
    }
    
    public func publishBlob<C>(_ blob: C) -> EventLoopFuture<ReferencedBlob<C>> where C : Decodable, C : Encodable {
        fatalError()
    }
    
    public func readPublishedBlob<C>(byId id: String, as type: C.Type) -> EventLoopFuture<ReferencedBlob<C>?> where C : Decodable, C : Encodable {
        fatalError()
    }
    
    public func sendMessage(_ message: RatchetedCypherMessage, toUser username: Username, otherUserDeviceId: DeviceId, messageId: String) -> EventLoopFuture<Void> {
        fatalError()
    }
    
    public func sendMultiRecipientMessage(_ message: MultiRecipientCypherMessage, messageId: String) -> EventLoopFuture<Void> {
        eventLoop.executeAsync {
            _ = try await self.httpClient.postBSON(
                url: "actions/send-message",
                username: self.username,
                deviceId: self.deviceId,
                token: self.makeToken(),
                body: SendMessage(message: message, messageId: messageId)
            )
        }
    }
}
