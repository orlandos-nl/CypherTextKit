enum CypherSDKError: Error {
    case offline
    case missingPublicKeys
    case cannotFindDeviceConfig
    case invalidMultiRecipientKey
    case notMasterDevice
    case invalidUserConfig
    case corruptUserConfig
    case badInput
    case unknownGroup
    case invalidDeliveryStateTransition
    case appLocked
    case invalidGroupConfig
}
