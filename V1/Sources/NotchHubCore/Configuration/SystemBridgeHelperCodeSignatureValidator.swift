import Foundation
import Security

public struct SystemBridgeHelperCodeSignatureValidator: BridgeHelperCodeSignatureValidating {
    public init() {}

    public func validateCode(at url: URL) throws -> BridgeHelperCodeIdentity {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw BridgeHelperInstallerError.invalidPath
        }

        var code: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard creationStatus == errSecSuccess, let code else {
            throw BridgeHelperInstallerError.invalidCodeSignature(status: creationStatus)
        }
        let validationStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            nil
        )
        guard validationStatus == errSecSuccess else {
            throw BridgeHelperInstallerError.invalidCodeSignature(status: validationStatus)
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [String: Any]
        else {
            throw BridgeHelperInstallerError.invalidCodeSignature(status: informationStatus)
        }
        let requirementText = try designatedRequirement(for: code)
        return BridgeHelperCodeIdentity(
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            signingIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
            designatedRequirement: requirementText,
            cdHash: information[kSecCodeInfoUnique as String] as? Data
        )
    }

    private func designatedRequirement(for code: SecStaticCode) throws -> String {
        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw BridgeHelperInstallerError.invalidCodeSignature(status: requirementStatus)
        }
        var requirementText: CFString?
        let stringStatus = SecRequirementCopyString(requirement, [], &requirementText)
        guard stringStatus == errSecSuccess, let requirementText else {
            throw BridgeHelperInstallerError.invalidCodeSignature(status: stringStatus)
        }
        return requirementText as String
    }
}
