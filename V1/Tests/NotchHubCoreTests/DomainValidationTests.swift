import Foundation
import Testing
@testable import NotchHubCore

@Suite("Provider domain validation")
struct DomainValidationTests {
    @Test("Quota percentages and durations are validated")
    func quotaValidation() throws {
        #expect(throws: ProviderError.self) {
            try QuotaWindow(id: "five-hour", label: "Five hour", usedPercent: -.infinity)
        }
        #expect(throws: ProviderError.self) {
            try QuotaWindow(id: "five-hour", label: "Five hour", usedPercent: 100.01)
        }
        #expect(throws: ProviderError.self) {
            try QuotaWindow(
                id: "five-hour",
                label: "Five hour",
                usedPercent: 10,
                windowDurationMinutes: 0
            )
        }

        let quota = try QuotaWindow(
            id: "five-hour",
            label: "Five hour",
            usedPercent: 42.5,
            windowDurationMinutes: 300
        )
        #expect(quota.usedPercent == 42.5)
    }

    @Test("Decoded quota payloads cannot bypass validation")
    func decodedQuotaValidation() {
        let payload = Data(
            #"{"id":"five-hour","label":"Five hour","usedPercent":130}"#.utf8
        )
        #expect(throws: ProviderError.self) {
            try JSONDecoder().decode(QuotaWindow.self, from: payload)
        }
    }

    @Test("Usage snapshots require unique windows and valid credits")
    func snapshotValidation() throws {
        let quota = try QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 25)
        #expect(throws: ProviderError.self) {
            try UsageSnapshot(provider: .codex, windows: [], capturedAt: .now)
        }
        #expect(throws: ProviderError.self) {
            try UsageSnapshot(provider: .codex, windows: [quota, quota], capturedAt: .now)
        }
        #expect(throws: ProviderError.self) {
            try UsageSnapshot(
                provider: .codex,
                windows: [quota],
                capturedAt: .now,
                creditsRemaining: -1
            )
        }
    }

    @Test("Project metadata never retains a full path")
    func projectNameSanitization() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = try AgentSession(
            id: "session-1",
            provider: .claude,
            projectName: "/fixture/private/work/NotchHub",
            status: .running,
            startedAt: start,
            updatedAt: start
        )
        #expect(session.projectName == "NotchHub")
        #expect(session.projectName?.contains("fixture") == false)
    }

    @Test("Sensitive project labels are redacted")
    func sensitiveProjectSanitization() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = try AgentSession(
            id: "session-1",
            provider: .claude,
            projectName: "/fixture/work/person@example.test",
            status: .running,
            startedAt: start,
            updatedAt: start
        )
        #expect(session.projectName == "Private project")
    }

    @Test("Command previews retain only the executable name")
    func commandPreviewSanitization() throws {
        let request = try approval(
            category: .command,
            preview: "/fixture/tools/deploy --token=never-store --target person@example.test",
            risk: .moderate
        )
        #expect(request.preview == "deploy …")
        #expect(!request.preview.contains("token"))
        #expect(!request.preview.contains("fixture"))
        #expect(!request.preview.contains("@"))
    }

    @Test("Network previews discard paths and query strings")
    func networkPreviewSanitization() throws {
        let request = try approval(
            category: .network,
            preview: "https://service.example.test/private?token=never-store",
            risk: .moderate
        )
        #expect(request.preview == "Connect to service.example.test")
    }

    @Test("Unstructured network and file text is not retained")
    func unstructuredPreviewSanitization() throws {
        let network = try approval(
            category: .network,
            preview: "private unstructured provider output",
            risk: .high
        )
        let file = try approval(
            category: .fileChange,
            preview: "private unstructured provider output",
            risk: .high
        )
        #expect(network.preview == "Use network")
        #expect(file.preview == "Change file")
    }

    @Test("Unknown actions are always assigned critical risk")
    func unknownActionRisk() throws {
        let request = try approval(category: .unknown, preview: "raw private content", risk: .low)
        #expect(request.risk == .critical)
        #expect(request.preview == "Unrecognized action")
    }

    @Test("Sanitized approvals round-trip without expanding their preview")
    func approvalCodableRoundTrip() throws {
        for category in ApprovalActionCategory.allCases {
            let request = try approval(category: category, preview: preview(for: category), risk: .high)
            let encoded = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: encoded)
            #expect(decoded == request)
        }
    }

    @Test("Session and approval identifiers are bounded")
    func identifierValidation() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(throws: ProviderError.self) {
            try AgentSession(
                id: "not allowed",
                provider: .codex,
                projectName: nil,
                status: .running,
                startedAt: start,
                updatedAt: start
            )
        }
    }

    @Test("Approval requests cannot outlive the bridge decision window")
    func approvalLifetimeValidation() {
        let received = Date(timeIntervalSince1970: 1000)
        #expect(throws: ProviderError.self) {
            try ApprovalRequest(
                id: "approval-1",
                provider: .codex,
                sessionID: "session-1",
                projectName: "Fixture",
                actionCategory: .tool,
                rawPreview: "read-file",
                risk: .low,
                receivedAt: received,
                expiresAt: received.addingTimeInterval(121)
            )
        }
    }

    private func approval(
        category: ApprovalActionCategory,
        preview: String,
        risk: ApprovalRisk
    ) throws -> ApprovalRequest {
        let received = Date(timeIntervalSince1970: 1000)
        return try ApprovalRequest(
            id: "approval-1",
            provider: .codex,
            sessionID: "session-1",
            projectName: "/fixture/work/NotchHub",
            actionCategory: category,
            rawPreview: preview,
            risk: risk,
            receivedAt: received,
            expiresAt: received.addingTimeInterval(120)
        )
    }

    private func preview(for category: ApprovalActionCategory) -> String {
        switch category {
        case .command: "/fixture/bin/git status --secret=hidden"
        case .fileChange: "/fixture/work/Package.swift"
        case .network: "https://service.example.test/private"
        case .tool: "read-file private-argument"
        case .unknown: "untrusted content"
        }
    }
}
