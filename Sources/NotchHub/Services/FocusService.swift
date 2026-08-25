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
///    Accessibility permission, and Automation permission for System Events.
///  - **State** is tracked locally (optimistic): we flip `isOn` when a toggle
///    succeeds. If Full Disk Access happens to be granted we reconcile against
///    the assertions file a moment later, but we never require it.
///
/// Two permissions, two very different fixes, so failures are classified
/// rather than collapsed into "something went wrong": a denied Apple Event and
/// a missing Accessibility grant live in different System Settings panes.
@MainActor
final class FocusService: ObservableObject {

    /// Why a toggle attempt did not take.
    enum ToggleError: Error, Equatable {
        /// NotchHub is not trusted for Accessibility, so it cannot drive UI.
        case accessibilityDenied
        /// The user declined (or has not yet allowed) NotchHub → System Events.
        case automationDenied
        /// The script ran but Control Center did not expose a Focus control —
        /// a renamed element, an unexpected locale, a macOS layout change.
        case controlNotFound
        /// Anything else AppleScript reported.
        case scriptFailed(code: Int?)

        /// The pane that fixes it, when a pane can.
        var settingsPane: SystemSettingsPane? {
            switch self {
            case .accessibilityDenied: .accessibility
            case .automationDenied: .automation
            case .controlNotFound, .scriptFailed: nil
            }
        }
    }

    @Published private(set) var isOn = false
    /// Whether `isOn` reflects something actually read, rather than a default.
    ///
    /// The real state lives in a file only Full Disk Access can read, and the
    /// Control Center control does not always publish its value. Without this
    /// flag the module claimed "Do Not Disturb is off" on a Mac where it was on,
    /// offered "Turn On", turned it *off*, and then showed a "Focus is on" pill
    /// for the rest of the session. Saying nothing is better than saying the
    /// opposite of the truth.
    @Published private(set) var isStateKnown = false
    /// Set when a toggle attempt fails, with the reason.
    @Published private(set) var lastError: ToggleError?
    /// Whether NotchHub currently has Accessibility permission, which the toggle
    /// requires. Surfaced in the UI proactively so the failure isn't silent.
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// True while a toggle is in flight — the script drives real UI and takes a
    /// beat, so the button should not look inert.
    @Published private(set) var isToggling = false

    /// Apple Events denial codes, matching `MediaService`: `errAEEventNotPermitted`
    /// and `procNotFound` (System Events not running / not permitted to launch).
    nonisolated static let automationErrorCodes: Set<Int> = [-1743, -600]
    /// How long to wait before trusting the assertions file. The DND daemon
    /// writes it asynchronously; reading immediately returns the pre-toggle
    /// value and would undo the optimistic flip we just made.
    nonisolated static let reconcileDelay: TimeInterval = 1.2

    private let assertionsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    /// `NSAppleScript` is not thread-safe; every execution goes through this one
    /// queue so two toggles can never run concurrently.
    private let scriptQueue = DispatchQueue(label: "com.notchhub.focus.applescript")

    /// Bumped by every toggle. A reconcile carries the number it was armed
    /// with and stands down if a newer toggle has happened since.
    private var toggleGeneration = 0

    private let isTrusted: @Sendable () -> Bool
    private let runScript: @Sendable () -> Result<Bool?, ToggleError>
    private let readState: @Sendable () -> Bool?
    private let promptForAccessibility: @Sendable () -> Void
    private let reconcile: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    init(
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        runScript: (@Sendable () -> Result<Bool?, ToggleError>)? = nil,
        readState: (@Sendable () -> Bool?)? = nil,
        promptForAccessibility: @escaping @Sendable () -> Void = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        reconcile: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
            = { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
    ) {
        let assertions = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        self.isTrusted = isTrusted
        self.runScript = runScript ?? { Self.runToggleScript() }
        self.readState = readState ?? { Self.readDoNotDisturb(at: assertions) }
        self.promptForAccessibility = promptForAccessibility
        self.reconcile = reconcile
        accessibilityGranted = isTrusted()
    }

    func start() {
        refreshAccessibility()
        // One best-effort sync in case Full Disk Access is granted; harmless
        // (and a no-op) otherwise.
        adoptState(readState())
    }

    /// Record a state we actually read. A `nil` reading is not a state — it
    /// means we could not tell, and the previous answer (or the lack of one)
    /// stands.
    private func adoptState(_ real: Bool?) {
        guard let real else { return }
        isOn = real
        isStateKnown = true
    }

    /// Re-check Accessibility permission (the user may grant it while the app
    /// runs). Cheap; call when the Focus module appears.
    func refreshAccessibility() {
        let granted = isTrusted()
        if granted != accessibilityGranted { accessibilityGranted = granted }
        // A grant that arrived since the last failure clears the stale message.
        if granted, lastError == .accessibilityDenied { lastError = nil }
    }

    /// Raise the system Accessibility prompt, which also adds NotchHub to the
    /// list in System Settings so there is a switch to flip. The non-prompting
    /// check alone never puts the app there, which is why the permission used
    /// to look ungrantable.
    func requestAccessibility() {
        promptForAccessibility()
        // The user grants in another app; re-read when they come back.
        refreshAccessibility()
    }

    func toggle() {
        guard !isToggling else { return }
        toggleGeneration &+= 1
        // Cheapest, most common failure first — no point scripting UI we are
        // not trusted to drive.
        guard isTrusted() else {
            accessibilityGranted = false
            lastError = .accessibilityDenied
            return
        }
        isToggling = true
        let run = runScript
        scriptQueue.async {
            let result = run()
            Task { @MainActor [weak self] in self?.finishToggle(result) }
        }
    }

    private func finishToggle(_ result: Result<Bool?, ToggleError>) {
        isToggling = false
        switch result {
        case .success(let reported):
            lastError = nil
            if let reported {
                // The script read the control back after clicking it, which is
                // the only reading that needs no Full Disk Access.
                adoptState(reported)
            } else if isStateKnown {
                // Nothing readable, but we knew where we started, so the flip
                // is sound.
                isOn.toggle()
            }
            scheduleReconciliation()
        case .failure(let error):
            lastError = error
            if error == .accessibilityDenied { accessibilityGranted = false }
        }
    }

    /// Correct the optimistic state from the real file, once it has had time to
    /// be written — and only if Full Disk Access lets us read it at all.
    private func scheduleReconciliation() {
        let read = readState
        // The file lags the click by up to `reconcileDelay`, so a reconcile
        // armed by an earlier toggle reads a value that predates a newer one.
        // Adopting it inverted the switch for about a second — and, when the
        // newer script reported nothing, `isOn.toggle()` then compounded the
        // error on top of the stale value.
        let generation = toggleGeneration
        reconcile(Self.reconcileDelay) {
            Task { @MainActor [weak self] in
                guard let self, self.toggleGeneration == generation else { return }
                self.adoptState(read())
            }
        }
    }

    // MARK: - Best-effort state read (requires Full Disk Access)

    /// Returns the real DND state, or nil if the file can't be read.
    nonisolated static func readDoNotDisturb(at url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url),
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

    // MARK: - Failure classification

    /// Turn an AppleScript failure into something that names the right fix.
    ///
    /// The two permission failures are indistinguishable from the message
    /// alone, so the error number carries it: Apple Events denials come back as
    /// -1743/-600, while Accessibility failures surface as -25211 or a message
    /// about assistive access.
    nonisolated static func classify(errorNumber: Int?, message: String?) -> ToggleError {
        if let errorNumber, automationErrorCodes.contains(errorNumber) {
            return .automationDenied
        }
        let text = (message ?? "").lowercased()
        if errorNumber == -25211 || text.contains("assistive access") || text.contains("not allowed assistive") {
            return .accessibilityDenied
        }
        if text.contains("no opener") || text.contains("no dnd control") {
            return .controlNotFound
        }
        return .scriptFailed(code: errorNumber)
    }

    // MARK: - Toggle via Control Center

    /// The Control Center walk, kept out of `runToggleScript` so the
    /// function reads as what it is: run this, classify what came back.
    nonisolated private static let toggleScriptSource = """
    tell application "System Events"
        tell process "ControlCenter"
            -- Open whichever menu-bar entry exposes Focus: a dedicated
            -- Focus item if the user shows one, else Control Center.
            -- Identifiers first: they don't change with the system language.
            set opener to missing value
            repeat with mbi in menu bar items of menu bar 1
                set ident to ""
                try
                    set ident to (value of attribute "AXIdentifier" of mbi) as text
                end try
                if ident contains "menuextra.focus" or ident contains "menuextra.donotdisturb" then
                    set opener to mbi
                    exit repeat
                end if
            end repeat
            if opener is missing value then
                repeat with mbi in menu bar items of menu bar 1
                    set ident to ""
                    try
                        set ident to (value of attribute "AXIdentifier" of mbi) as text
                    end try
                    if ident contains "controlcenter" then
                        set opener to mbi
                        exit repeat
                    end if
                end repeat
            end if
            if opener is missing value then
                repeat with mbi in menu bar items of menu bar 1
                    set d to ""
                    try
                        set d to (description of mbi)
                    end try
                    if d contains "Focus" or d contains "Do Not Disturb" or d contains "Control" then
                        set opener to mbi
                        exit repeat
                    end if
                end repeat
            end if
            if opener is missing value then error "no opener"
            click opener
            delay 0.4

            -- Everything past this point runs with a Control Center panel on
            -- screen. An error here used to abort with it still open, covering
            -- the menu bar and swallowing the user's next click, so the panel is
            -- closed on the way out however this ends.
            set resulting to "unknown"
            try

                -- Find the Do Not Disturb control. Identifiers first, for the same
                -- reason as the opener: descriptions are user-facing text and are
                -- translated ("Nicht stören", "Ne pas déranger"), so matching them
                -- alone made this feature dead on every non-English Mac.
                --
                -- Two passes, bounded to the front window: walking every window's
                -- entire contents is what made this take seconds. If the control is
                -- not at the top level we are in Control Center rather than the
                -- Focus menu extra, so drill into the Focus tile and look again.
                set dndControl to missing value
                repeat with pass from 1 to 2
                    if (count of windows) > 0 then
                        repeat with el in (entire contents of window 1)
                            set ident to ""
                            try
                                set ident to (value of attribute "AXIdentifier" of el) as text
                            end try
                            set d to ""
                            try
                                set d to (description of el) as text
                            end try
                            if ident contains "do-not-disturb" or ident contains "donotdisturb" ¬
                                or ident contains "dnd" or d contains "Do Not Disturb" then
                                set dndControl to el
                                exit repeat
                            end if
                        end repeat
                    end if
                    if dndControl is not missing value then exit repeat
                    if pass is 2 then exit repeat

                    set focusTile to missing value
                    if (count of windows) > 0 then
                        repeat with el in (entire contents of window 1)
                            set ident to ""
                            try
                                set ident to (value of attribute "AXIdentifier" of el) as text
                            end try
                            set d to ""
                            try
                                set d to (description of el) as text
                            end try
                            if ident contains "focus" or d is "Focus" then
                                set focusTile to el
                                exit repeat
                            end if
                        end repeat
                    end if
                    if focusTile is missing value then exit repeat
                    click focusTile
                    delay 0.35
                end repeat

                if dndControl is missing value then error "no dnd control"

                click dndControl
                delay 0.35

                -- Read the control back before closing. This is the only way to
                -- learn the real state without Full Disk Access; when the control
                -- publishes no value we say so rather than guessing.
                try
                    if (value of dndControl as integer) is 1 then
                        set resulting to "on"
                    else
                        set resulting to "off"
                    end if
                end try
            on error errorMessage number errorNumber
                try
                    key code 53
                end try
                error errorMessage number errorNumber
            end try
            key code 53
            return resulting
        end tell
    end tell
    """

    /// Drive Control Center's Focus control.
    ///
    /// Elements are matched by `AXIdentifier` first — those are stable across
    /// languages — and only fall back to matching the human-readable
    /// description, which changes with the user's locale.
    ///
    /// Returns the resulting Do Not Disturb state when Control Center published
    /// it, and `nil` when the click landed but the control said nothing about
    /// its value.
    nonisolated private static func runToggleScript() -> Result<Bool?, ToggleError> {
        let source = Self.toggleScriptSource
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed(code: nil))
        }
        let descriptor = script.executeAndReturnError(&error)
        guard let error else { return .success(reportedState(descriptor.stringValue)) }

        let number = error[NSAppleScript.errorNumber] as? Int
        let message = error[NSAppleScript.errorMessage] as? String
        let classified = classify(errorNumber: number, message: message)
        NSLog("NotchHub: Focus toggle failed (\(number.map(String.init) ?? "no code")): \(message ?? "no message")")
        return .failure(classified)
    }

    /// What the script said the control read after being clicked.
    nonisolated static func reportedState(_ output: String?) -> Bool? {
        switch output?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "on": true
        case "off": false
        default: nil
        }
    }
}
