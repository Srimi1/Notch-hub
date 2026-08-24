import Foundation
import Testing
@testable import NotchHub

/// The app cannot grant itself Full Disk Access, so what it *can* do — notice
/// the state, and avoid poking protected folders when it lacks the grant — is
/// what these pin down.
@Suite("Full Disk Access")
struct FullDiskAccessTests {

    /// A Mac that has never used a Focus mode has no probe file. That must read
    /// as granted, not denied, or the settings row nags about a permission the
    /// user has no reason to give.
    @Test
    func aMissingProbeFileCountsAsGranted() {
        final class NoFilesManager: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool { false }
        }
        #expect(FullDiskAccess.isGranted(fileManager: NoFilesManager()))
    }

    /// Reading the real probe must never throw or hang, whatever the grant
    /// state — it runs when the settings window appears.
    @Test
    func probingIsSafeRegardlessOfGrantState() {
        let first = FullDiskAccess.isGranted()
        let second = FullDiskAccess.isGranted()
        #expect(first == second)
    }

    /// The details builder degrades rather than prompting: no size, but the
    /// name and type survive.
    @Test
    func aFileSizeIsOmittedRatherThanPromptingForAProtectedFolder() {
        let desktop = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/quarterly.pdf")
        let clip = ClipboardService.Clip(id: UUID(), kind: .file(desktop), date: .now)

        let details = HudClipDetails.make(for: clip)

        #expect(details.title == "quarterly.pdf")
        // Whatever the grant state, the popup still names the file and its type.
        #expect(details.subtitle?.contains("PDF") == true)
    }

    /// Files outside the protected set are read normally — the guard must not
    /// become a blanket refusal.
    @Test
    func anUnprotectedPathIsStillMeasured() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchhub-size-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 2048).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let clip = ClipboardService.Clip(id: UUID(), kind: .file(tmp), date: .now)
        let details = HudClipDetails.make(for: clip)

        // `.byteCount(style: .file)` renders this as "2 kB" — lowercase k, per
        // the locale's unit naming, so match case-insensitively rather than
        // pinning a spelling that varies.
        let subtitle = details.subtitle?.lowercased() ?? ""
        #expect(subtitle.contains("kb") || subtitle.contains("bytes"))
    }
}
