enum CypherSDKError: Error {
    case offline
    case missingPublicKeys
    case cannotFindDeviceConfig
    case invalidMultiRecipientKey
    case notMasterDevice
    case invalidUserConfig
    case corruptUserConfig
    case badInput
    case unknownChat, unknownGroup
    case invalidDeliveryStateTransition
    case appLocked
    case invalidGroupConfig
    case invalidHandshake
    case incorrectAppPassword
    case invalidTransport
    case unsupportedTransport
    case internalError
    case notGroupMember, notGroupModerator
}
