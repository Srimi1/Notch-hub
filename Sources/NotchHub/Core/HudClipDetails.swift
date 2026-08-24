import Foundation
import UniformTypeIdentifiers

/// The two lines the copy HUD shows for a clip. Pure and synchronous so it can
/// be unit-tested and is only ever computed for the single clip on screen.
struct HudClipDetails: Equatable {
    let title: String
    /// "1.2 MB · Spreadsheet" for files, pixel size for images, nil for text —
    /// the user asked for "a little bit of file information, not too broad".
    let subtitle: String?

    static func make(
        for clip: ClipboardService.Clip,
        fileSize: (URL) -> Int? = Self.fileSize(of:)
    ) -> HudClipDetails {
        switch clip.kind {
        case .text(let text):
            return HudClipDetails(title: snippet(of: text), subtitle: nil)
        case .image:
            return HudClipDetails(title: "Image", subtitle: "From the clipboard")
        case .file(let url):
            let parts = [
                fileSize(url).map { $0.formatted(.byteCount(style: .file)) },
                typeName(of: url)
            ].compactMap(\.self)
            return HudClipDetails(
                title: url.lastPathComponent,
                subtitle: parts.isEmpty ? nil : parts.joined(separator: " · ")
            )
        }
    }

    /// First line of the text, hard-capped so a copied novel stays one line.
    private static func snippet(of text: String, limit: Int = 80) -> String {
        let line = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "Empty text" }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// "Spreadsheet", "PDF document", "MPEG-4 movie" — whatever the system
    /// calls the type. Falls back to the bare extension rather than guessing.
    private static func typeName(of url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return url.pathExtension.isEmpty ? nil : url.pathExtension.uppercased()
        }
        return type.localizedDescription ?? type.preferredFilenameExtension?.uppercased()
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
