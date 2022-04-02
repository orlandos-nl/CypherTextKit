import CypherMessaging
import NIO

fileprivate struct UserVerificationMetadata: Codable {
    var isVerified: Bool
}

@available(macOS 10.15, iOS 13, *)
public struct UserVerificationPlugin: Plugin {
    public static let pluginIdentifier = "@/user-verification"
    
    public init() {}
}

@available(macOS 10.15, iOS 13, *)
extension Contact {
    @MainActor public var isVerified: Bool {
        (try? self.model.getProp(
            ofType: UserVerificationMetadata.self,
            forPlugin: UserVerificationPlugin.self,
            run: \.isVerified
        )) ?? false
    }
    
    @MainActor func setVerification(to isVerified: Bool) async throws {
        try await modifyMetadata(
            ofType: UserVerificationMetadata.self,
            forPlugin: UserVerificationPlugin.self
        ) { metadata in
            metadata.isVerified = isVerified
        }
    }
}
