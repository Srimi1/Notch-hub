import Foundation

public enum TelemetrySeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct TelemetryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let severity: TelemetrySeverity
    public let category: String
    public let code: String
    public let summary: String

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        severity: TelemetrySeverity,
        category: String,
        code: String,
        summary: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.severity = severity
        self.category = category
        self.code = code
        self.summary = summary
    }
}

public actor LocalTelemetryConsole {
    private let capacity: Int
    private var entries: [TelemetryEntry] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, min(capacity, 1_000))
    }

    public func record(
        severity: TelemetrySeverity,
        category: String,
        code: String,
        summary: String,
        at date: Date = Date()
    ) {
        let entry = TelemetryEntry(
            capturedAt: date,
            severity: severity,
            category: SupportLogRedactor.identifier(category),
            code: SupportLogRedactor.identifier(code),
            summary: SupportLogRedactor.summary(summary)
        )
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func snapshot() -> [TelemetryEntry] {
        entries
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}

public enum SupportLogRedactor {
    private static let maximumSummaryLength = 240
    private static let maximumIdentifierLength = 48

    public static func identifier(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        }
        let normalized = String(String.UnicodeScalarView(allowed))
        return String(normalized.prefix(maximumIdentifierLength))
    }

    public static func summary(_ value: String) -> String {
        var result = printableText(value)
        result = replace(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: result,
            with: "<redacted-email>"
        )
        result = replace(
            pattern: #"(?i)(bearer\s+|sk-)[A-Za-z0-9._-]{8,}"#,
            in: result,
            with: "<redacted-secret>"
        )
        result = replace(
            pattern: #"/Users/[^/\s]+/"#,
            in: result,
            with: "~/"
        )
        return String(result.prefix(maximumSummaryLength))
    }

    private static func printableText(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar == "\n" || scalar == "\t" {
                return " "
            }
            return CharacterSet.controlCharacters.contains(scalar) ? "�" : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func replace(
        pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        } catch {
            return "<redaction-error>"
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
