import Foundation
import Testing
@testable import NotchHubBridge
@testable import NotchHubCore

@Suite("Hook configuration planner")
struct HookConfigurationPlannerTests {
    private let planner = HookConfigurationPlanner()
    private let home = "/tmp/notchhub-fixture-home"
    private let bridge = "/Applications/NotchHub Preview.app/Contents/Helpers/NotchHubHookBridge"

    @Test("Codex install preserves settings and is idempotent")
    func codexInstallation() throws {
        let installation = try codexInstallationPlan()
        let installedData = try #require(installation.atomicWrite?.data)
        let installedRoot = try rootObject(installedData)

        #expect(installation.diff.change == .update)
        #expect(installation.diff.addedOwnedEntryIDs.count == 4)
        #expect(installation.atomicWrite?.fileMode == 0o600)
        #expect(installedRoot["theme"] as? String == "dark")
        #expect(containsHookCommand("/usr/bin/true", root: installedRoot))
        try assertOfficialCodexShape(installedRoot)

        let installedInput = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: installedData,
            fileKind: .regularFile
        )
        let secondInstallation = try planner.planConnection(
            provider: .codex,
            input: installedInput,
            bridgeExecutablePath: bridge
        )
        #expect(secondInstallation.diff.change == .unchanged)
        #expect(secondInstallation.diff.addedOwnedEntryIDs.isEmpty)
        #expect(secondInstallation.atomicWrite == nil)
    }

    @Test("Codex disconnect removes exactly owned entries")
    func codexRemoval() throws {
        let installation = try codexInstallationPlan()
        let installedData = try #require(installation.atomicWrite?.data)
        let installedInput = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: installedData,
            fileKind: .regularFile
        )
        let removal = try planner.planDisconnection(provider: .codex, input: installedInput)
        let removedData = try #require(removal.atomicWrite?.data)
        let removedRoot = try rootObject(removedData)
        let removedText = try #require(String(bytes: removedData, encoding: .utf8))

        #expect(removal.diff.removedOwnedEntryIDs.count == 4)
        #expect(removedRoot["theme"] as? String == "dark")
        #expect(containsHookCommand("/usr/bin/true", root: removedRoot))
        #expect(!removedText.contains(HookConfigurationPlanner.ownerPrefix))
    }

    @Test("Claude install preserves unrelated hook groups and supports exact removal")
    func claudeLifecycle() throws {
        let original = Data(#"{"env":{"SAFE":"1"},"hooks":{"Stop":[{"matcher":"custom","hooks":["#.utf8)
            + Data(#"{"type":"command","command":"/usr/bin/true","timeout":5}]}]}}"#.utf8)
        let input = HookConfigurationInput(homeDirectoryPath: home, existingData: original, fileKind: .regularFile)
        let installation = try planner.planConnection(provider: .claude, input: input, bridgeExecutablePath: bridge)
        let installedData = try #require(installation.atomicWrite?.data)
        let installedRoot = try rootObject(installedData)
        let installedText = try #require(String(bytes: installedData, encoding: .utf8))

        #expect(containsClaudeCommand("/usr/bin/true", root: installedRoot))
        #expect(installedText.contains("NotchHub Preview.app"))
        #expect(installedText.contains("--notchhub-hook-id"))
        #expect(installation.diff.addedOwnedEntryIDs.count == 5)
        #expect(installation.diff.compatibility == .fullyConfigured)
        #expect((installedRoot["statusLine"] as? [String: Any]) != nil)

        let installedInput = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: installedData,
            fileKind: .regularFile
        )
        let removal = try planner.planDisconnection(provider: .claude, input: installedInput)
        let removedData = try #require(removal.atomicWrite?.data)
        let removedText = try #require(String(bytes: removedData, encoding: .utf8))
        let removedRoot = try rootObject(removedData)

        #expect(containsClaudeCommand("/usr/bin/true", root: removedRoot))
        #expect(!removedText.contains(HookConfigurationPlanner.ownerPrefix))
        #expect((removedRoot["env"] as? [String: String]) == ["SAFE": "1"])
        #expect(removedRoot["statusLine"] == nil)
    }

    @Test("Claude-owned status line is idempotent")
    func ownedClaudeStatusLineIsIdempotent() throws {
        let missing = HookConfigurationInput(homeDirectoryPath: home, existingData: nil, fileKind: .missing)
        let first = try planner.planConnection(provider: .claude, input: missing, bridgeExecutablePath: bridge)
        let firstData = try #require(first.atomicWrite?.data)
        let firstRoot = try rootObject(firstData)
        let statusLine = try #require(firstRoot["statusLine"] as? [String: Any])
        let command = try #require(statusLine["command"] as? String)

        #expect(command.contains("--event 'StatusLine'"))
        #expect(command.contains("com.notchhub.v1.claude.statusline"))

        let installed = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: firstData,
            fileKind: .regularFile
        )
        let second = try planner.planConnection(provider: .claude, input: installed, bridgeExecutablePath: bridge)
        #expect(second.diff.change == .unchanged)
        #expect(second.diff.addedOwnedEntryIDs.isEmpty)
        #expect(second.diff.compatibility == .fullyConfigured)
    }

    @Test("Custom Claude status line is preserved with a compatibility state")
    func customClaudeStatusLineIsPreserved() throws {
        let original = Data(
            #"{"statusLine":{"type":"command","command":"/usr/local/bin/my-status","padding":2},"theme":"dark"}"#.utf8
        )
        let input = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: original,
            fileKind: .regularFile
        )
        let connection = try planner.planConnection(
            provider: .claude,
            input: input,
            bridgeExecutablePath: bridge
        )
        let connectedData = try #require(connection.atomicWrite?.data)
        let connectedRoot = try rootObject(connectedData)
        let customStatusLine = try #require(connectedRoot["statusLine"] as? [String: Any])

        #expect(connection.diff.compatibility == .customClaudeStatusLinePreserved)
        #expect(connection.diff.addedOwnedEntryIDs.count == 4)
        #expect(customStatusLine["command"] as? String == "/usr/local/bin/my-status")
        #expect(customStatusLine["padding"] as? Int == 2)

        let connectedInput = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: connectedData,
            fileKind: .regularFile
        )
        let removal = try planner.planDisconnection(provider: .claude, input: connectedInput)
        let removedData = try #require(removal.atomicWrite?.data)
        let removedRoot = try rootObject(removedData)
        let preserved = try #require(removedRoot["statusLine"] as? [String: Any])
        #expect(removal.diff.compatibility == .customClaudeStatusLinePreserved)
        #expect(preserved["command"] as? String == "/usr/local/bin/my-status")
    }

    @Test("Missing configuration creates a deterministic atomic-write preparation")
    func missingConfiguration() throws {
        let input = HookConfigurationInput(homeDirectoryPath: home, existingData: nil, fileKind: .missing)
        let plan = try planner.planConnection(provider: .codex, input: input, bridgeExecutablePath: bridge)

        #expect(plan.diff.change == .create)
        #expect(plan.diff.destinationPath == home + "/.codex/hooks.json")
        #expect(plan.atomicWrite?.temporarySiblingPath == home + "/.codex/hooks.json.notchhub-v1.pending")
    }

    @Test("Malformed roots and hook shapes are rejected")
    func malformedConfiguration() {
        let malformed = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: Data("{".utf8),
            fileKind: .regularFile
        )
        #expect(throws: HookConfigurationError.malformedJSON) {
            try planner.planConnection(provider: .codex, input: malformed, bridgeExecutablePath: bridge)
        }

        let invalidHooks = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: Data(#"{"hooks":"unsafe"}"#.utf8),
            fileKind: .regularFile
        )
        #expect(throws: HookConfigurationError.invalidHooksShape("codex.hooks")) {
            try planner.planConnection(provider: .codex, input: invalidHooks, bridgeExecutablePath: bridge)
        }
    }

    @Test("Oversized configurations are rejected before JSON parsing")
    func oversizedConfiguration() {
        let input = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: Data(repeating: 0x20, count: HookConfigurationPlanner.maximumConfigurationBytes + 1),
            fileKind: .regularFile
        )

        #expect(
            throws: HookConfigurationError.configurationTooLarge(
                limit: HookConfigurationPlanner.maximumConfigurationBytes
            )
        ) {
            try planner.planConnection(provider: .codex, input: input, bridgeExecutablePath: bridge)
        }
    }

    @Test("Symlinked files and ancestors are rejected before parsing")
    func symlinksRejected() {
        let fileLink = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: Data("{}".utf8),
            fileKind: .symbolicLink
        )
        #expect(throws: HookConfigurationError.symbolicLinkRejected) {
            try planner.planConnection(provider: .codex, input: fileLink, bridgeExecutablePath: bridge)
        }

        let ancestorLink = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: nil,
            fileKind: .missing,
            ancestorContainsSymbolicLink: true
        )
        #expect(throws: HookConfigurationError.symbolicLinkRejected) {
            try planner.planConnection(provider: .claude, input: ancestorLink, bridgeExecutablePath: bridge)
        }
    }

    @Test("An owned identifier with altered content is a conflict")
    func ownedEntryConflict() throws {
        let input = HookConfigurationInput(homeDirectoryPath: home, existingData: nil, fileKind: .missing)
        let plan = try planner.planConnection(provider: .codex, input: input, bridgeExecutablePath: bridge)
        var root = try rootObject(#require(plan.atomicWrite?.data))
        var hooks = try #require(root["hooks"] as? [String: Any])
        var groups = try #require(hooks["SessionStart"] as? [[String: Any]])
        var commands = try #require(groups[0]["hooks"] as? [[String: Any]])
        commands[0]["command"] = "/usr/bin/false --notchhub-hook-id 'com.notchhub.v1.codex.sessionstart'"
        groups[0]["hooks"] = commands
        hooks["SessionStart"] = groups
        root["hooks"] = hooks
        let conflictedData = try JSONSerialization.data(withJSONObject: root)
        let conflictedInput = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: conflictedData,
            fileKind: .regularFile
        )

        #expect(throws: HookConfigurationError.conflictingOwnedEntry("com.notchhub.v1.codex.sessionstart")) {
            try planner.planConnection(provider: .codex, input: conflictedInput, bridgeExecutablePath: bridge)
        }
        #expect(throws: HookConfigurationError.conflictingOwnedEntry("com.notchhub.v1.codex.sessionstart")) {
            try planner.planDisconnection(provider: .codex, input: conflictedInput)
        }
    }
}

private extension HookConfigurationPlannerTests {
    private func rootObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func codexInstallationPlan() throws -> HookConfigurationPlan {
        let original = Data(
            #"""
            {
              "theme": "dark",
              "hooks": {
                "SessionStart": [
                  {"matcher": "custom", "hooks": [{"type": "command", "command": "/usr/bin/true", "timeout": 5}]}
                ]
              }
            }
            """#.utf8
        )
        let input = HookConfigurationInput(
            homeDirectoryPath: home,
            existingData: original,
            fileKind: .regularFile
        )
        return try planner.planConnection(provider: .codex, input: input, bridgeExecutablePath: bridge)
    }

    private func containsClaudeCommand(_ expectedCommand: String, root: [String: Any]) -> Bool {
        containsHookCommand(expectedCommand, root: root)
    }

    private func containsHookCommand(_ expectedCommand: String, root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else {
                return false
            }
            return groups.contains { group in
                guard let commands = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return commands.contains { ($0["command"] as? String) == expectedCommand }
            }
        }
    }

    private func assertOfficialCodexShape(_ root: [String: Any]) throws {
        let hooks = try #require(root["hooks"] as? [String: Any])
        for event in ["SessionStart", "PermissionRequest", "Stop", "SessionEnd"] {
            let groups = try #require(hooks[event] as? [[String: Any]])
            let owned = try #require(groups.last)
            #expect(owned["matcher"] as? String == "")
            let handlers = try #require(owned["hooks"] as? [[String: Any]])
            let handler = try #require(handlers.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["command"] is String)
            if event == "SessionEnd" {
                #expect((handler["timeout"] as? Int) == 3)
            }
        }
    }
}
