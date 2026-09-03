extension ProviderError {
    var directAgentTelemetryCode: String {
        switch self {
        case .cliNotFound: "cli-not-found"
        case .signedOut: "signed-out"
        case .unsupportedVersion: "unsupported-version"
        case .timeout: "timeout"
        case .malformedResponse: "malformed-response"
        case .offline: "offline"
        case .hookConflict: "hook-conflict"
        case .processFailed: "process-failed"
        case .cancelled: "cancelled"
        case .adapterUnavailable: "adapter-unavailable"
        case .approvalResponderUnavailable: "approval-responder-unavailable"
        case .approvalNotFound: "approval-not-found"
        case .approvalExpired: "approval-expired"
        case .approvalInProgress: "approval-in-progress"
        case .invalidPayload: "invalid-payload"
        }
    }
}

extension DirectAgentRuntime {
    func record(
        _ error: ProviderError,
        operation: String,
        severity: TelemetrySeverity = .error
    ) async {
        await record(
            severity: severity,
            code: "\(error.directAgentTelemetryCode)-\(operation)",
            summary: error.errorDescription ?? "Provider operation failed."
        )
    }

    func record(
        severity: TelemetrySeverity,
        code: String,
        summary: String
    ) async {
        await telemetry.record(
            DirectAgentRuntimeTelemetryEvent(
                severity: severity,
                code: code,
                summary: summary
            )
        )
    }

    static func initialState(for provider: ProviderID) -> ProviderRuntimeState {
        ProviderRuntimeState(
            provider: provider,
            connectionState: .notDetected,
            usageSnapshot: nil,
            snapshotSource: nil,
            executableSource: nil
        )
    }
}
