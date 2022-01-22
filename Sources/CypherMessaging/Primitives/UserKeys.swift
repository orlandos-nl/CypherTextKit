import Foundation
import CypherProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The user's private keys are only stored on the user's main device
public struct DevicePrivateKeys: Codable {
    private enum CodingKeys: String, CodingKey {
        case deviceId = "a"
        case identity = "b"
        case privateKey = "c"
    }
    
    public let deviceId: DeviceId
    /// Identity is used for signing messages in name of a user
    public let identity: PrivateSigningKey
    public let privateKey: PrivateKey
    
    public init(deviceId: DeviceId = DeviceId()) {
        self.identity = PrivateSigningKey()
        self.deviceId = deviceId
        self.privateKey = PrivateKey()
    }
}

public struct UserConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case identity = "a"
        case devices = "b"
    }
    
    /// Identity is a public key used to validate messages sidned by `identity`
    /// This is the main device's identity, which when trusted verified all other devices' validity
    public let identity: PublicSigningKey
    
    /// Devices are signed by `identity`, so you only need to trust `identity`'s validity
    private var devices: Signed<[UserDeviceConfig]>
    
    public init(mainDevice: DevicePrivateKeys, otherDevices: [UserDeviceConfig]) throws {
        self.identity = mainDevice.identity.publicKey
        
        var devices = otherDevices
        devices.append(
            UserDeviceConfig(
                deviceId: mainDevice.deviceId,
                identity: mainDevice.identity.publicKey,
                publicKey: mainDevice.privateKey.publicKey,
                isMasterDevice: true
            )
        )
        
        self.devices = try Signed(
            devices,
            signedBy: mainDevice.identity
        )
    }
    
    public mutating func addDeviceConfig(
        _ config: UserDeviceConfig,
        signedWith identity: PrivateSigningKey
    ) throws {
        var devices = try readAndValidateDevices()
        
        if devices.contains(where: { $0.deviceId == config.deviceId }) {
            return
        }
        
        devices.append(config)
        self.devices = try Signed(devices, signedBy: identity)
    }
    
    public func readAndValidateDevices() throws -> [UserDeviceConfig] {
        try devices.readAndVerifySignature(signedBy: identity)
    }
}

public struct UserDeviceConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case deviceId = "a"
        case identity = "b"
        case publicKey = "c"
        case isMasterDevice = "d"
    }
    
    public let deviceId: DeviceId
    public let identity: PublicSigningKey
    public let publicKey: PublicKey
    public let isMasterDevice: Bool
    
    public init(
        deviceId: DeviceId,
        identity: PublicSigningKey,
        publicKey: PublicKey,
        isMasterDevice: Bool
    ) {
        self.deviceId = deviceId
        self.identity = identity
        self.publicKey = publicKey
        self.isMasterDevice = isMasterDevice
    }
}
