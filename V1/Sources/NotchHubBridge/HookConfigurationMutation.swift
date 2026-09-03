import Foundation

extension HookConfigurationPlanner {
    struct ClaudeStatusLineMutation {
        let ownedEntryID: String?
        let compatibility: HookConfigurationCompatibility
    }

    private struct OwnedCommandLocation {
        let groupIndex: Int
        let commandCount: Int
        let command: [String: Any]
    }

    func installCodexEntries(root: inout [String: Any], bridgePath: String) throws -> [String] {
        try installGroupedEntries(
            root: &root,
            provider: .codex,
            events: Self.codexEvents,
            bridgePath: bridgePath
        )
    }

    func removeCodexEntries(root: inout [String: Any]) throws -> [String] {
        try removeGroupedEntries(root: &root, provider: .codex, events: Self.codexEvents)
    }

    func installClaudeEntries(root: inout [String: Any], bridgePath: String) throws -> [String] {
        try installGroupedEntries(
            root: &root,
            provider: .claude,
            events: Self.claudeEvents,
            bridgePath: bridgePath
        )
    }

    func removeClaudeEntries(root: inout [String: Any]) throws -> [String] {
        try removeGroupedEntries(root: &root, provider: .claude, events: Self.claudeEvents)
    }

    func installClaudeStatusLine(
        root: inout [String: Any],
        bridgePath: String
    ) throws -> ClaudeStatusLineMutation {
        let event = BridgeHookEventName.statusLine.rawValue
        let id = ownedID(provider: .claude, event: event)
        let command = providerCommand(provider: .claude, id: id, event: event, bridgePath: bridgePath)
        let expected: [String: Any] = [
            "command": command,
            "type": "command",
        ]
        guard let current = root["statusLine"] else {
            root["statusLine"] = expected
            return ClaudeStatusLineMutation(ownedEntryID: id, compatibility: .fullyConfigured)
        }
        guard let currentObject = current as? [String: Any],
              commandContainsOwnedID(currentObject, id: id)
        else {
            return ClaudeStatusLineMutation(
                ownedEntryID: nil,
                compatibility: .customClaudeStatusLinePreserved
            )
        }
        guard dictionariesEqual(currentObject, expected) else {
            throw HookConfigurationError.conflictingOwnedEntry(id)
        }
        return ClaudeStatusLineMutation(ownedEntryID: nil, compatibility: .fullyConfigured)
    }

    func removeClaudeStatusLine(root: inout [String: Any]) throws -> ClaudeStatusLineMutation {
        guard let current = root["statusLine"] else {
            return ClaudeStatusLineMutation(ownedEntryID: nil, compatibility: .fullyConfigured)
        }
        let id = ownedID(provider: .claude, event: BridgeHookEventName.statusLine.rawValue)
        guard let currentObject = current as? [String: Any],
              commandContainsOwnedID(currentObject, id: id)
        else {
            return ClaudeStatusLineMutation(
                ownedEntryID: nil,
                compatibility: .customClaudeStatusLinePreserved
            )
        }
        guard Set(currentObject.keys) == Set(["command", "type"]),
              currentObject["type"] as? String == "command",
              let command = currentObject["command"] as? String,
              isCanonicalOwnedCommand(command, provider: .claude, event: "StatusLine", id: id)
        else {
            throw HookConfigurationError.conflictingOwnedEntry(id)
        }
        root.removeValue(forKey: "statusLine")
        return ClaudeStatusLineMutation(ownedEntryID: id, compatibility: .fullyConfigured)
    }

    private func installGroupedEntries(
        root: inout [String: Any],
        provider: HookConfigurationProvider,
        events: [String],
        bridgePath: String
    ) throws -> [String] {
        var hooks = try hooksObject(from: root, provider: provider)
        var addedIDs: [String] = []
        for event in events {
            var groups = try objectArray(hooks[event], field: "hooks.\(event)")
            let id = ownedID(provider: provider, event: event)
            let command = providerCommand(provider: provider, id: id, event: event, bridgePath: bridgePath)
            let expectedHandler = commandHandler(command: command, event: event)
            let matches = try ownedCommandLocations(in: groups, id: id, provider: provider)
            if matches.isEmpty {
                groups.append(commandGroup(handler: expectedHandler))
                addedIDs.append(id)
            } else {
                let match = matches[0]
                guard matches.count == 1,
                      isGeneratedGroup(groups[match.groupIndex]),
                      match.commandCount == 1,
                      dictionariesEqual(match.command, expectedHandler)
                else {
                    throw HookConfigurationError.conflictingOwnedEntry(id)
                }
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return addedIDs.sorted()
    }

    private func removeGroupedEntries(
        root: inout [String: Any],
        provider: HookConfigurationProvider,
        events: [String]
    ) throws -> [String] {
        guard root["hooks"] != nil else {
            return []
        }
        var hooks = try hooksObject(from: root, provider: provider)
        var removedIDs: [String] = []
        for event in events where hooks[event] != nil {
            let id = ownedID(provider: provider, event: event)
            let groups = try objectArray(hooks[event], field: "hooks.\(event)")
            let retained = try removingOwnedCommand(
                id: id,
                provider: provider,
                event: event,
                groups: groups,
                removedIDs: &removedIDs
            )
            if retained.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = retained
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return removedIDs
    }

    private func removingOwnedCommand(
        id: String,
        provider: HookConfigurationProvider,
        event: String,
        groups: [[String: Any]],
        removedIDs: inout [String]
    ) throws -> [[String: Any]] {
        var retainedGroups: [[String: Any]] = []
        for var group in groups {
            var commands = try objectArray(group["hooks"], field: "\(provider.rawValue).hooks.\(event)[].hooks")
            var retainedCommands: [[String: Any]] = []
            for command in commands {
                guard commandContainsOwnedID(command, id: id) else {
                    retainedCommands.append(command)
                    continue
                }
                guard commands.count == 1,
                      isGeneratedGroup(group),
                      isCanonicalOwnedHandler(command, provider: provider, event: event, id: id)
                else {
                    throw HookConfigurationError.conflictingOwnedEntry(id)
                }
                removedIDs.append(id)
            }
            commands = retainedCommands
            if commands.isEmpty, isGeneratedGroup(group) {
                continue
            }
            group["hooks"] = commands
            retainedGroups.append(group)
        }
        return retainedGroups
    }
}

extension HookConfigurationPlanner {
    func hooksObject(
        from root: [String: Any],
        provider: HookConfigurationProvider
    ) throws -> [String: Any] {
        guard let value = root["hooks"] else {
            return [:]
        }
        guard let hooks = value as? [String: Any] else {
            throw HookConfigurationError.invalidHooksShape("\(provider.rawValue).hooks")
        }
        return hooks
    }

    func objectArray(_ value: Any?, field: String) throws -> [[String: Any]] {
        guard let value else {
            return []
        }
        guard let values = value as? [Any] else {
            throw HookConfigurationError.invalidHooksShape(field)
        }
        return try values.map { value in
            guard let object = value as? [String: Any] else {
                throw HookConfigurationError.invalidHooksShape(field)
            }
            return object
        }
    }

    func ownedID(provider: HookConfigurationProvider, event: String) -> String {
        "\(Self.ownerPrefix).\(provider.rawValue).\(event.lowercased())"
    }

    private func commandGroup(handler: [String: Any]) -> [String: Any] {
        [
            "hooks": [handler],
            "matcher": "",
        ]
    }

    private func commandHandler(command: String, event: String) -> [String: Any] {
        var handler: [String: Any] = [
            "command": command,
            "timeout": timeout(for: event),
            "type": "command",
        ]
        if event != "PermissionRequest", event != "SessionEnd" {
            handler["async"] = true
        }
        return handler
    }

    private func providerCommand(
        provider: HookConfigurationProvider,
        id: String,
        event: String,
        bridgePath: String
    ) -> String {
        [
            shellQuote(bridgePath),
            "--provider", shellQuote(provider.rawValue),
            "--event", shellQuote(event),
            "--notchhub-hook-id", shellQuote(id),
        ].joined(separator: " ")
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func ownedCommandLocations(
        in groups: [[String: Any]],
        id: String,
        provider: HookConfigurationProvider
    ) throws -> [OwnedCommandLocation] {
        var results: [OwnedCommandLocation] = []
        for (groupIndex, group) in groups.enumerated() {
            let commands = try objectArray(group["hooks"], field: "\(provider.rawValue).hooks[].hooks")
            for command in commands where commandContainsOwnedID(command, id: id) {
                results.append(
                    OwnedCommandLocation(
                        groupIndex: groupIndex,
                        commandCount: commands.count,
                        command: command
                    )
                )
            }
        }
        return results
    }

    private func isCanonicalOwnedHandler(
        _ handler: [String: Any],
        provider: HookConfigurationProvider,
        event: String,
        id: String
    ) -> Bool {
        guard let command = handler["command"] as? String,
              isCanonicalOwnedCommand(command, provider: provider, event: event, id: id)
        else {
            return false
        }
        return dictionariesEqual(handler, commandHandler(command: command, event: event))
    }

    private func isCanonicalOwnedCommand(
        _ command: String,
        provider: HookConfigurationProvider,
        event: String,
        id: String
    ) -> Bool {
        let suffix = [
            "--provider", shellQuote(provider.rawValue),
            "--event", shellQuote(event),
            "--notchhub-hook-id", shellQuote(id),
        ].joined(separator: " ")
        let separatorAndSuffix = " " + suffix
        guard command.hasSuffix(separatorAndSuffix) else {
            return false
        }
        let quotedPath = String(command.dropLast(separatorAndSuffix.count))
        guard let path = shellUnquote(quotedPath),
              path.hasPrefix("/"),
              !path.contains("\0"),
              URL(fileURLWithPath: path).lastPathComponent == "NotchHubHookBridge"
        else {
            return false
        }
        return shellQuote(path) == quotedPath
    }

    private func shellUnquote(_ value: String) -> String? {
        guard value.first == "'", value.last == "'" else {
            return nil
        }
        let inner = value.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    private func commandContainsOwnedID(_ command: [String: Any], id: String) -> Bool {
        guard let commandText = command["command"] as? String else {
            return false
        }
        return commandText.hasSuffix("--notchhub-hook-id \(shellQuote(id))")
    }

    private func isGeneratedGroup(_ group: [String: Any]) -> Bool {
        Set(group.keys) == Set(["hooks", "matcher"]) && (group["matcher"] as? String) == ""
    }

    private func timeout(for event: String) -> Int {
        switch event {
        case "PermissionRequest": 120
        case "SessionEnd": 3
        case "SessionStart", "Stop": 10
        default: 10
        }
    }

    private func dictionariesEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }
}
