import Foundation

/// Errors exposed by provider integrations. Associated values intentionally avoid
/// carrying raw provider output, file paths, commands, or account identifiers.
public enum ProviderError: Error, Codable, Hashable, Sendable {
    case cliNotFound(provider: ProviderID)
    case signedOut(provider: ProviderID)
    case unsupportedVersion(provider: ProviderID)
    case timeout(provider: ProviderID)
    case malformedResponse(provider: ProviderID)
    case offline(provider: ProviderID)
    case hookConflict(provider: ProviderID)
    case processFailed(provider: ProviderID, exitCode: Int32)
    case cancelled(provider: ProviderID)
    case adapterUnavailable(provider: ProviderID)
    case approvalResponderUnavailable(provider: ProviderID)
    case approvalNotFound
    case approvalExpired
    case approvalInProgress
    case invalidPayload(provider: ProviderID?, field: String)
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .cliNotFound(provider):
            "\(provider.displayName) CLI was not found."
        case let .signedOut(provider):
            "\(provider.displayName) is not signed in."
        case let .unsupportedVersion(provider):
            "The installed \(provider.displayName) CLI version is not supported."
        case let .timeout(provider):
            "\(provider.displayName) did not respond before the deadline."
        case let .malformedResponse(provider):
            "\(provider.displayName) returned an unreadable response."
        case let .offline(provider):
            "\(provider.displayName) is unavailable while offline."
        case let .hookConflict(provider):
            "\(provider.displayName) already has an incompatible hook configuration."
        case let .processFailed(provider, exitCode):
            "\(provider.displayName) exited with status \(exitCode)."
        case let .cancelled(provider):
            "\(provider.displayName) refresh was cancelled."
        case let .adapterUnavailable(provider):
            "No usage adapter is registered for \(provider.displayName)."
        case let .approvalResponderUnavailable(provider):
            "No approval responder is registered for \(provider.displayName)."
        case .approvalNotFound:
            "The approval request is no longer available."
        case .approvalExpired:
            "The approval request has expired."
        case .approvalInProgress:
            "A response to this approval request is already in progress."
        case let .invalidPayload(provider, field):
            if let provider {
                "\(provider.displayName) returned an invalid \(field) value."
            } else {
                "An invalid \(field) value was received."
            }
        }
    }
}

public extension ProviderError {
    static func wrapping(_ error: any Error, provider: ProviderID) -> ProviderError {
        if let providerError = error as? ProviderError {
            return providerError
        }

        if error is CancellationError {
            return .cancelled(provider: provider)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff:
                return .offline(provider: provider)
            case .timedOut:
                return .timeout(provider: provider)
            default:
                return .malformedResponse(provider: provider)
            }
        }

        return .malformedResponse(provider: provider)
    }
}
