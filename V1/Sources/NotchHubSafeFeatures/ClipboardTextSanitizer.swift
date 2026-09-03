import Foundation

struct ClipboardSanitizedText: Sendable, Equatable {
    let text: String
    let wasTruncated: Bool
}

actor ClipboardTextSanitizer {
    func sanitize(_ data: Data, maximumCharacters: Int) -> ClipboardSanitizedText? {
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        let withoutNulls = decoded.replacingOccurrences(of: "\0", with: "")
        let bounded = String(withoutNulls.prefix(maximumCharacters))
        return ClipboardSanitizedText(
            text: bounded,
            wasTruncated: withoutNulls.count > maximumCharacters
        )
    }
}
