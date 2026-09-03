import Foundation
import NotchHubBridge
import Security

public enum SessionBridgeAction: Sendable, Equatable {
    case connect
    case disconnect
    case retryStartup

    public var buttonLabel: String {
        switch self {
        case .connect: "Connect sessions…"
        case .disconnect: "Disconnect…"
        case .retryStartup: "Retry bridge"
        }
    }
}

public enum SessionBridgeConnectionPresentation: Sendable, Equatable {
    case checking
    case disconnected
    case connected
    case connectedWithCustomClaudeStatusLine
    case unavailable(String)
    case startupFailed(String)
    case failed(String)

    public var label: String {
        switch self {
        case .checking: "Checking session hooks"
        case .disconnected: "Terminal sessions are not connected"
        case .connected: "Codex and Claude sessions are connected"
        case .connectedWithCustomClaudeStatusLine: "Sessions connected; your Claude status line was preserved"
        case let .unavailable(message), let .startupFailed(message), let .failed(message): message
        }
    }

    public var action: SessionBridgeAction? {
        switch self {
        case .checking, .unavailable: nil
        case .startupFailed: .retryStartup
        case .disconnected, .failed: .connect
        case .connected, .connectedWithCustomClaudeStatusLine: .disconnect
        }
    }

    public static func startupFailure(for error: any Error) -> Self {
        if let transportError = error as? BridgeTransportError {
            switch transportError {
            case let .keychainSharingUnavailable(status) where status == errSecMissingEntitlement:
                return .unavailable(
                    "Session bridge unavailable in this build; provider prompts remain active."
                )
            default:
                break
            }
        }
        return .startupFailed(
            "Session bridge could not start. Retry or restart NotchHub; provider prompts remain active."
        )
    }
}
