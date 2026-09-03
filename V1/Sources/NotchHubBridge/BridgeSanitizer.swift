import Foundation

public enum BridgeSanitizer {
    private static let replacement = "[redacted]"
    private static let sensitiveMarkers = [
        "access_token", "api_key", "apikey", "authorization", "bearer", "credential", "ghp_", "github_pat_",
        "password", "secret", "sk-", "token=", "xoxb-", "xoxp-",
    ]

    public static func identifier(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard !trimmed.isEmpty,
              trimmed.count <= BridgeProtocolConstants.maximumIdentifierLength,
              trimmed.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw BridgeProtocolError.invalidIdentifier(field)
        }
        return trimmed
    }

    public static func nonce(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !trimmed.isEmpty,
              trimmed.count <= BridgeProtocolConstants.maximumNonceLength,
              trimmed.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw BridgeProtocolError.invalidNonce
        }
        return trimmed
    }

    public static func optionalProjectLabel(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        return optionalLabel(lastComponent ?? normalized)
    }

    public static func optionalLabel(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let sanitized = label(value)
        return sanitized.isEmpty ? nil : sanitized
    }

    public static func label(_ value: String) -> String {
        let visibleScalars = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let visible = String(String.UnicodeScalarView(visibleScalars))
        let words = visible.split(whereSeparator: { $0.isWhitespace })
        let sanitizedWords = words.map { word -> String in
            let candidate = String(word)
            let lowercased = candidate.lowercased()
            if looksLikeEmail(candidate) || sensitiveMarkers.contains(where: lowercased.contains) {
                return replacement
            }
            return candidate
        }
        let normalized = sanitizedWords.joined(separator: " ")
        return String(normalized.prefix(BridgeProtocolConstants.maximumLabelLength))
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        guard let atIndex = value.firstIndex(of: "@"), atIndex != value.startIndex else {
            return false
        }
        let domainStart = value.index(after: atIndex)
        guard domainStart < value.endIndex else {
            return false
        }
        return value[domainStart...].contains(".")
    }
}
