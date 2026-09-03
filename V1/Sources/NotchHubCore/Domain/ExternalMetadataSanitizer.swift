import Foundation

public enum ExternalMetadataSanitizer {
    private static let identifierCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._:")
    )

    public static func identifier(_ rawValue: String, field: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128 else {
            throw ProviderError.invalidPayload(provider: nil, field: field)
        }
        guard value.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            throw ProviderError.invalidPayload(provider: nil, field: field)
        }
        return value
    }

    public static func displayText(_ rawValue: String, field: String, limit: Int) throws -> String {
        let value = collapsedText(rawValue)
        guard !value.isEmpty, value.count <= limit, !containsSensitiveToken(value) else {
            throw ProviderError.invalidPayload(provider: nil, field: field)
        }
        return value
    }

    public static func projectName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let collapsed = collapsedText(rawValue)
        guard !collapsed.isEmpty else { return nil }

        let normalized = collapsed.replacingOccurrences(of: "\\", with: "/")
        let component = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
            ?? normalized
        guard !containsSensitiveToken(component) else { return "Private project" }
        return bounded(component, limit: 80)
    }

    public static func actionPreview(
        _ rawValue: String?,
        category: ApprovalActionCategory
    ) -> String {
        guard let rawValue else { return fallback(for: category) }
        let collapsed = collapsedText(rawValue)
        guard !collapsed.isEmpty else { return fallback(for: category) }

        switch category {
        case .command:
            return commandPreview(collapsed)
        case .fileChange:
            return filePreview(collapsed)
        case .network:
            return networkPreview(collapsed)
        case .tool:
            return toolPreview(collapsed)
        case .unknown:
            return fallback(for: .unknown)
        }
    }

    private static func collapsedText(_ value: String) -> String {
        let printableScalars = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                return " "
            }
            return Character(String(scalar))
        }
        return String(printableScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func commandPreview(_ value: String) -> String {
        guard let firstToken = value.split(separator: " ").first else {
            return fallback(for: .command)
        }
        let executable = String(firstToken)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? "Command"
        guard !containsSensitiveToken(executable) else { return fallback(for: .command) }
        return "\(bounded(executable, limit: 48)) …"
    }

    private static func filePreview(_ value: String) -> String {
        let content = value.hasPrefix("Change ") ? String(value.dropFirst("Change ".count)) : value
        let normalized = content.replacingOccurrences(of: "\\", with: "/")
        let component = normalized.split(separator: "/").last.map(String.init) ?? "file"
        guard !component.contains(where: \.isWhitespace), !containsSensitiveToken(component) else {
            return fallback(for: .fileChange)
        }
        let safeComponent = bounded(component, limit: 64)
        return "Change \(safeComponent)"
    }

    private static func networkPreview(_ value: String) -> String {
        let content = value.hasPrefix("Connect to ") ? String(value.dropFirst("Connect to ".count)) : value
        let host: String? = if let url = URL(string: content), let urlHost = url.host {
            urlHost
        } else {
            content.split(separator: "/").first.map(String.init)
        }
        guard let host, isSafeNetworkHost(host), !containsSensitiveToken(host) else {
            return fallback(for: .network)
        }
        return "Connect to \(bounded(host, limit: 80))"
    }

    private static func toolPreview(_ value: String) -> String {
        let content = value.hasPrefix("Use ") ? String(value.dropFirst("Use ".count)) : value
        let tool = content.split(separator: " ").first.map(String.init) ?? "tool"
        guard !containsSensitiveToken(tool) else { return fallback(for: .tool) }
        return "Use \(bounded(tool, limit: 64))"
    }

    private static func containsSensitiveToken(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let markers = ["@", "token=", "secret=", "password=", "apikey=", "api_key="]
        return markers.contains(where: normalized.contains)
    }

    private static func isSafeNetworkHost(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func fallback(for category: ApprovalActionCategory) -> String {
        switch category {
        case .command: "Run command"
        case .fileChange: "Change file"
        case .network: "Use network"
        case .tool: "Use tool"
        case .unknown: "Unrecognized action"
        }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(limit - 1, 0))) + "…"
    }
}
