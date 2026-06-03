import AppKit
import ApplicationServices
import Combine
import Foundation

/// Do Not Disturb toggle.
///
/// macOS exposes no public API to set a Focus, and the only file that records
/// the current state (`~/Library/DoNotDisturb/DB/Assertions.json`) is
/// TCC-protected (needs Full Disk Access). So the design here is:
///
///  - **Toggle** by driving Control Center through accessibility scripting —
///    the same path a person takes clicking the menu-bar Focus control. Needs
///    Accessibility permission (System Settings ▸ Privacy ▸ Accessibility).
///  - **State** is tracked locally (optimistic): we flip `isOn` when a toggle
///    succeeds. If Full Disk Access happens to be granted we correct it from
///    the assertions file, but we never require it.
final class FocusService: ObservableObject {

    @Published private(set) var isOn = false
    /// Set when a toggle attempt fails — almost always missing Accessibility.
    @Published private(set) var lastToggleFailed = false
    /// Whether NotchHub currently has Accessibility permission, which the toggle
    /// requires. Surfaced in the UI proactively so the failure isn't silent.
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private let assertionsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    func start() {
        refreshAccessibility()
        // One best-effort sync in case Full Disk Access is granted; harmless
        // (and a no-op) otherwise.
        if let real = readDoNotDisturb() { isOn = real }
    }

    /// Re-check Accessibility permission (the user may grant it while the app
    /// runs). Cheap; call when the Focus module appears.
    func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted { accessibilityGranted = granted }
    }

    func toggle() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = self?.runToggleScript() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastToggleFailed = !ok
                if ok { self.isOn.toggle() }
                // Correct from the real file if we're allowed to read it.
                if let real = self.readDoNotDisturb() { self.isOn = real }
            }
        }
    }

    // MARK: - Best-effort state read (requires Full Disk Access)

    /// Returns the real DND state, or nil if the file can't be read.
    private func readDoNotDisturb() -> Bool? {
        guard let data = try? Data(contentsOf: assertionsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return nil }

        for entry in entries {
            if let records = entry["storeAssertionRecords"] as? [Any], !records.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Toggle via Control Center

    /// Drive Control Center's Focus control. Element descriptions vary slightly
    /// across macOS versions/locales, so we match loosely and fail gracefully.
    private func runToggleScript() -> Bool {
        let source = """
        tell application "System Events"
            tell process "ControlCenter"
                -- Open whichever menu-bar entry exposes Focus: a dedicated
                -- Focus item if the user shows one, else Control Center.
                set opener to missing value
                repeat with mbi in menu bar items of menu bar 1
                    set d to ""
                    try
                        set d to (description of mbi)
                    end try
                    if d contains "Focus" or d contains "Do Not Disturb" then
                        set opener to mbi
                        exit repeat
                    end if
                end repeat
                if opener is missing value then
                    repeat with mbi in menu bar items of menu bar 1
                        set d to ""
                        try
                            set d to (description of mbi)
                        end try
                        if d contains "Control" then
                            set opener to mbi
                            exit repeat
                        end if
                    end repeat
                end if
                if opener is missing value then error "no opener"
                click opener
                delay 0.4

                -- If we opened Control Center, drill into its Focus tile first.
                repeat with w in windows
                    repeat with el in (entire contents of w)
                        try
                            if (description of el) is "Focus" then
                                click el
                                delay 0.35
                                exit repeat
                            end if
                        end try
                    end repeat
                end repeat

                -- Click the Do Not Disturb control wherever it now lives.
                set toggled to false
                repeat with w in windows
                    repeat with el in (entire contents of w)
                        try
                            if (description of el) contains "Do Not Disturb" then
                                click el
                                set toggled to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if toggled then exit repeat
                end repeat
                key code 53
                if not toggled then error "no dnd control"
            end tell
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        return error == nil
    }
}
