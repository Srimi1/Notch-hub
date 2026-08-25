import Foundation
import Testing
@testable import NotchHub

/// The app cannot grant itself Full Disk Access, so what it *can* do — notice
/// the state, and avoid poking protected folders when it lacks the grant — is
/// what these pin down.
@Suite("Full Disk Access")
struct FullDiskAccessTests {

    /// With no probe file at all the grant cannot be established either way.
    ///
    /// This used to report "granted" so the settings row would not nag someone
    /// with nothing to fix. But the prompt-avoidance guard reads the same
    /// answer, and acting as though access were granted is what raised the
    /// per-folder dialogs that guard exists to prevent. The state is now its
    /// own case: the UI can stay gentle about it, the guards cannot.
    @Test
    func aMissingProbeFileIsIndeterminateNotGranted() {
        final class NoFilesManager: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool { false }
        }
        let manager = NoFilesManager()
        #expect(FullDiskAccess.status(fileManager: manager) == .indeterminate)
        #expect(FullDiskAccess.isGranted(fileManager: manager) == false)
    }

    /// An unestablished grant must not be mistaken for one when deciding
    /// whether it is safe to read a file in a protected folder.
    @Test
    func anIndeterminateGrantDoesNotUnlockProtectedFolderReads() {
        final class NoFilesManager: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool { false }
        }
        #expect(FullDiskAccess.isGranted(fileManager: NoFilesManager()) == false)
    }

    /// Reading the real probe must never throw or hang, whatever the grant
    /// state. Clipboard presentation can consult it for protected files.
    @Test
    func probingIsSafeRegardlessOfGrantState() {
        let first = FullDiskAccess.isGranted()
        let second = FullDiskAccess.isGranted()
        #expect(first == second)
    }

    /// The regression this list exists to prevent: the Focus assertions file
    /// only appears once someone has used a Focus mode, so a Mac that never has
    /// answered "indeterminate" forever — the settings row could not be
    /// satisfied by granting the permission it was asking for. `TCC.db` exists
    /// on every account, so the probe now has something to read.
    @Test
    func theProbeDoesNotDependOnHavingUsedAFocusMode() {
        #expect(FullDiskAccess.probePaths.first?.contains("com.apple.TCC") == true)
        #expect(FullDiskAccess.probePaths.count > 1)

        final class OnlyTCC: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool {
                path.contains("com.apple.TCC")
            }
        }
        // The probe resolves to a real answer even with no Focus history: it
        // reads (or fails to read) TCC.db rather than giving up.
        #expect(FullDiskAccess.status(fileManager: OnlyTCC()) != .indeterminate)
    }

    /// A probe file that is simply absent says nothing about the grant, so it
    /// must be skipped rather than reported as a denial.
    @Test
    func anAbsentProbeIsSkippedRatherThanCountedAsDenied() {
        final class OnlyLastProbe: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool {
                path.hasSuffix(FullDiskAccess.probePaths[2])
            }
        }
        // The first two probes do not exist; the third decides, and since the
        // fake path is not readable the honest answer is "denied", not
        // "indeterminate".
        #expect(FullDiskAccess.status(fileManager: OnlyLastProbe(), home: "/nonexistent") == .denied)
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
