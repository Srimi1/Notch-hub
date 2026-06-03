import Combine
import Foundation

/// Owns the "passwordless purge" capability for the RAM cleaner.
///
/// `/usr/sbin/purge` requires root. By default the cleaner elevates per-clean
/// through macOS's secure auth dialog (Touch ID / password), which the OS only
/// caches for ~5 minutes — so frequent cleans keep re-prompting. To offer a true
/// "ask once, never again" experience we install a single, tightly-scoped sudoers
/// rule:
///
///     <user> ALL=(root) NOPASSWD: /usr/sbin/purge
///
/// at `/etc/sudoers.d/notchhub`. That grants the current user passwordless sudo
/// for exactly one harmless binary (a cache flush) and nothing else. Installing it
/// costs one admin prompt; afterwards the cleaner runs `sudo -n /usr/sbin/purge`
/// silently. The rule is validated with `visudo` *before* it touches the real
/// config (so a malformed line can never break sudo), installed `0440 root:wheel`,
/// and is fully revocable.
final class PurgePrivilege: ObservableObject {

    /// True when `/usr/sbin/purge` can run via sudo with no password — i.e. the
    /// sudoers rule is installed and valid. The runtime probe is the source of
    /// truth, so this self-heals if the file is removed outside the app.
    @Published private(set) var isPasswordless = false

    static let sudoersPath = "/etc/sudoers.d/notchhub"
    private static let purgePath = "/usr/sbin/purge"
    private static let sudoPath = "/usr/bin/sudo"

    // MARK: - Probe

    /// Refresh the capability without ever prompting. `sudo -n -l <cmd>` exits 0
    /// when the command is allowed passwordless and non-zero otherwise, and never
    /// blocks for input thanks to `-n`. Runs off the main thread; publishes back.
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let allowed = Self.probePasswordless()
            DispatchQueue.main.async { self?.isPasswordless = allowed }
        }
    }

    private static func probePasswordless() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: sudoPath)
        task.arguments = ["-n", "-l", purgePath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Enable / revoke

    /// Install the passwordless rule via a single admin prompt, then re-probe so
    /// `isPasswordless` reflects reality. Fire-and-forget: the UI reacts to the
    /// published change. Runs off the main thread so the auth dialog never blocks
    /// the UI.
    func enableAlwaysAllow() {
        // Build the rule for the current user; bail if the name isn't a plain
        // account name (defensive against injection into the sudoers line).
        guard let line = Self.sudoersLine(for: NSUserName()) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Write the candidate rule to a user temp file (no privileges needed),
            // then let one elevated step validate + install it atomically.
            let tmp = NSTemporaryDirectory() + "notchhub-\(UUID().uuidString).sudoers"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            guard (try? line.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return }

            let cmd = "/usr/sbin/visudo -cf '\(tmp)' && "
                + "/usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(Self.sudoersPath)'"
            _ = Self.runElevated(cmd)
            self.refresh()
        }
    }

    /// Remove the rule (revoke). One admin prompt, then re-probe.
    func disableAlwaysAllow() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = Self.runElevated("/bin/rm -f '\(Self.sudoersPath)'")
            self.refresh()
        }
    }

    // MARK: - Helpers

    /// The sudoers rule granting passwordless `/usr/sbin/purge` to `user`, or
    /// `nil` when the name isn't a plain account name. Pure + internal so it can
    /// be unit-tested without touching the system.
    static func sudoersLine(for user: String) -> String? {
        guard isSafeUsername(user) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(purgePath)\n"
    }

    /// A real account name is alphanumerics / `.` / `_` / `-`; anything else
    /// (whitespace, shell metacharacters, newlines) is rejected.
    static func isSafeUsername(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// Run a shell command elevated through macOS's secure auth dialog. Mirrors
    /// `MemoryCleanerService`'s NSAppleScript pattern. Returns true on success;
    /// a user-cancel (-128) or any auth/exec failure returns false.
    @discardableResult
    private static func runElevated(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        return error == nil
    }
}
