import CryptoKit
import Foundation

public enum BridgeHookEventName: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    case statusLine = "StatusLine"
}

public struct BridgeHookInvocation: Equatable, Sendable {
    public let provider: ProviderID
    public let event: BridgeHookEventName
    public let hookID: String

    public init(provider: ProviderID, event: BridgeHookEventName, hookID: String) throws {
        let expectedID = "\(HookConfigurationPlanner.ownerPrefix).\(provider.rawValue).\(event.rawValue.lowercased())"
        guard hookID == expectedID, event != .statusLine || provider == .claude else {
            throw BridgeProviderHookError.invalidArguments
        }
        self.provider = provider
        self.event = event
        self.hookID = hookID
    }

    public static func parse(arguments: [String]) throws -> Self {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--provider", "--event", "--notchhub-hook-id"].contains(key),
                  values[key] == nil,
                  index + 1 < arguments.count
            else {
                throw BridgeProviderHookError.invalidArguments
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let providerValue = values["--provider"],
              let provider = ProviderID(rawValue: providerValue),
              let eventValue = values["--event"],
              let event = BridgeHookEventName(rawValue: eventValue),
              let hookID = values["--notchhub-hook-id"]
        else {
            throw BridgeProviderHookError.invalidArguments
        }
        return try Self(provider: provider, event: event, hookID: hookID)
    }
}

public enum BridgeProviderHookError: Error, Equatable, Sendable {
    case invalidArguments
    case malformedInput
    case oversizedInput
    case mismatchedEvent
    case missingSession
    case outputEncodingFailed
}

public enum BridgeProviderHookCodec {
    public static func request(
        from data: Data,
        invocation: BridgeHookInvocation,
        now: Date,
        requestNonce: String
    ) throws -> BridgeRequestEnvelope {
        guard !data.isEmpty else {
            throw BridgeProviderHookError.malformedInput
        }
        guard data.count <= BridgeProtocolConstants.maximumPayloadBytes else {
            throw BridgeProviderHookError.oversizedInput
        }
        let root = try rootObject(from: data)
        if let inputEvent = root["hook_event_name"] as? String, inputEvent != invocation.event.rawValue {
            throw BridgeProviderHookError.mismatchedEvent
        }
        guard let rawSessionID = root["session_id"] as? String, !rawSessionID.isEmpty else {
            throw BridgeProviderHookError.missingSession
        }
        let sessionID = safeIdentifier(rawSessionID, namespace: "session")
        let project = root["cwd"] as? String
        let event: BridgeEvent
        switch invocation.event {
        case .permissionRequest:
            event = try .approval(approvalEvent(root: root, invocation: invocation, sessionID: sessionID, now: now))
        case .sessionStart, .stop, .sessionEnd:
            event = try .session(
                sessionEvent(root: root, invocation: invocation, sessionID: sessionID, project: project, now: now)
            )
        case .statusLine:
            event = try .statusLine(
                BridgeStatusLineEvent(
                    provider: invocation.provider,
                    sessionID: sessionID,
                    rateLimits: rateLimits(from: root),
                    capturedAt: now
                )
            )
        }
        return try BridgeRequestEnvelope(nonce: requestNonce, event: event)
    }

    public static func providerOutput(
        for response: BridgeResponseEnvelope,
        request: BridgeRequestEnvelope? = nil,
        invocation: BridgeHookInvocation
    ) throws -> Data? {
        if invocation.provider == .codex, invocation.event == .stop {
            return Data("{}".utf8)
        }
        if invocation.event == .statusLine {
            return statusLineOutput(for: request, invocation: invocation)
        }
        guard invocation.event == .permissionRequest else {
            return nil
        }
        let behavior: String
        switch response.verdict {
        case .allowOnce:
            behavior = "allow"
        case .deny:
            behavior = "deny"
        case .abstain:
            return nil
        }
        let output = PermissionOutput(
            hookSpecificOutput: .init(
                hookEventName: BridgeHookEventName.permissionRequest.rawValue,
                decision: .init(behavior: behavior)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(output)
        } catch {
            throw BridgeProviderHookError.outputEncodingFailed
        }
    }

    public static func statusLineOutput(
        for request: BridgeRequestEnvelope?,
        invocation: BridgeHookInvocation
    ) -> Data? {
        guard invocation.provider == .claude,
              invocation.event == .statusLine,
              let request,
              case let .statusLine(event) = request.event
        else {
            return nil
        }
        let values = event.rateLimits.map { window in
            let label = switch window.id {
            case .fiveHour: "5h"
            case .sevenDay: "7d"
            }
            return "\(label) \(Int(window.usedPercent.rounded()))%"
        }
        let usage = values.isEmpty ? "usage unavailable" : values.joined(separator: " · ")
        return Data("NotchHub · \(usage)".utf8)
    }

    private static func rootObject(from data: Data) throws -> [String: Any] {
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BridgeProviderHookError.malformedInput
            }
            return root
        } catch let error as BridgeProviderHookError {
            throw error
        } catch {
            throw BridgeProviderHookError.malformedInput
        }
    }

    private static func approvalEvent(
        root: [String: Any],
        invocation: BridgeHookInvocation,
        sessionID: String,
        now: Date
    ) throws -> BridgeApprovalRequest {
        let toolName = (root["tool_name"] as? String).map(BridgeSanitizer.label) ?? "Unknown tool"
        let category = actionCategory(toolName: toolName)
        let sourceID = [sessionID, root["turn_id"] as? String ?? "", toolName, String(now.timeIntervalSince1970)]
            .joined(separator: ":")
        return try BridgeApprovalRequest(
            approvalID: safeIdentifier(sourceID, namespace: "approval"),
            provider: invocation.provider,
            sessionID: sessionID,
            projectLabel: root["cwd"] as? String,
            actionCategory: category,
            targetLabel: toolName,
            expiresAt: now.addingTimeInterval(120)
        )
    }

    private static func sessionEvent(
        root: [String: Any],
        invocation: BridgeHookInvocation,
        sessionID: String,
        project: String?,
        now: Date
    ) throws -> BridgeSessionEvent {
        let sourceID = [sessionID, invocation.event.rawValue, String(now.timeIntervalSince1970)].joined(separator: ":")
        return try BridgeSessionEvent(
            eventID: safeIdentifier(sourceID, namespace: "event"),
            provider: invocation.provider,
            sessionID: sessionID,
            state: lifecycleState(event: invocation.event),
            projectLabel: project,
            occurredAt: now
        )
    }

    private static func rateLimits(from root: [String: Any]) throws -> [BridgeRateLimitWindow] {
        guard let rawRateLimits = root["rate_limits"] else {
            return []
        }
        guard let rateLimits = rawRateLimits as? [String: Any] else {
            throw BridgeProviderHookError.malformedInput
        }
        let specifications: [(String, BridgeRateLimitWindowID)] = [
            ("five_hour", .fiveHour),
            ("seven_day", .sevenDay),
        ]
        return try specifications.compactMap { key, id in
            guard let rawWindow = rateLimits[key] else {
                return nil
            }
            guard let window = rawWindow as? [String: Any] else {
                throw BridgeProviderHookError.malformedInput
            }
            guard let rawUsage = window["used_percentage"], !(rawUsage is NSNull) else {
                return nil
            }
            let usedPercent = try finiteNumber(rawUsage)
            guard (0 ... 100).contains(usedPercent) else {
                throw BridgeProviderHookError.malformedInput
            }
            let resetsAt: Date?
            if let rawReset = window["resets_at"], !(rawReset is NSNull) {
                let resetEpoch = try finiteNumber(rawReset)
                guard resetEpoch >= 0 else {
                    throw BridgeProviderHookError.malformedInput
                }
                resetsAt = Date(timeIntervalSince1970: resetEpoch)
            } else {
                resetsAt = nil
            }
            return try BridgeRateLimitWindow(id: id, usedPercent: usedPercent, resetsAt: resetsAt)
        }
    }

    private static func finiteNumber(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            throw BridgeProviderHookError.malformedInput
        }
        return number.doubleValue
    }

    private static func safeIdentifier(_ value: String, namespace: String) -> String {
        do {
            return try BridgeSanitizer.identifier(value, field: namespace)
        } catch {
            let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            return "\(namespace)-\(digest)"
        }
    }

    private static func actionCategory(toolName: String) -> BridgeActionCategory {
        switch toolName.lowercased() {
        case "bash", "shell", "terminal": .processExecution
        case "apply_patch", "edit", "write", "notebookedit": .fileWrite
        case "read", "grep", "glob": .fileRead
        case "webfetch", "websearch": .networkAccess
        default: .unknown
        }
    }

    private static func lifecycleState(event: BridgeHookEventName) -> BridgeLifecycleState {
        switch event {
        case .sessionStart: .started
        case .stop: .running
        case .sessionEnd: .ended
        case .permissionRequest: .waitingForApproval
        case .statusLine: .running
        }
    }
}

private extension BridgeProviderHookCodec {
    struct PermissionOutput: Encodable {
        let hookSpecificOutput: HookSpecificOutput
    }

    struct HookSpecificOutput: Encodable {
        let hookEventName: String
        let decision: Decision
    }

    struct Decision: Encodable {
        let behavior: String
    }
}
