import Combine
import Foundation

/// One-tap RAM cleaner — the official, honest way.
///
/// There is no public API to free another process's memory, and the old
/// "allocation pressure" trick (malloc + memset gigabytes to force eviction)
/// backfires on modern macOS: evicted pages get compressed (compressed memory
/// counts as *used*) and can spill to swap, so RAM usage actually climbs.
///
/// Instead we run Apple's own `/usr/sbin/purge`, which truly flushes the
/// inactive / speculative / file-backed cache back to free **without quitting
/// apps** — active working sets are untouched, so the user's workflow isn't
/// disturbed. `purge` requires root, so we invoke it through macOS's secure
/// authorization dialog (Touch ID / password) via NSAppleScript with
/// administrator privileges. macOS caches that authorization for ~5 minutes, so
/// back-to-back cleans don't re-prompt.
///
/// The "Freed" figure is the genuine drop in **Memory Used** (active + wired +
/// compressed) measured around the purge — the same quantity Activity Monitor
/// reports. We deliberately do *not* measure the rise in the free list: `purge`
/// flushes file cache from inactive→free, which inflates `free_count` by GBs
/// without reducing Memory Used at all, so a free-list delta would claim
/// phantom gigabytes the user can't corroborate in Activity Monitor. Since
/// purge leaves the working set untouched, the honest figure is usually ≈0 →
/// the UI then says "Already optimized" rather than a number.
///
/// Alongside cleaning we publish a live memory breakdown (app / cached /
/// compressed / swap) so the user understands their memory at a glance.
final class MemoryCleanerService: ObservableObject {

    enum State: Equatable { case idle, cleaning, done, cancelled, needsPermission, failed }

    @Published private(set) var state: State = .idle
    /// MB reclaimed by the most recent successful clean. `nil` after a clean
    /// that freed nothing meaningful → UI shows "Already optimized" instead of 0.
    @Published private(set) var lastFreedMB: Double?
    /// Activity-Monitor "Memory Used" before/after the last clean, so the UI can
    /// show the real, persistent reduction (e.g. "Used 8.7 → 7.3 GB").
    @Published private(set) var lastUsedBeforeGB: Double = 0
    @Published private(set) var lastUsedAfterGB: Double = 0

    // Live breakdown, refreshed cheaply off the monitor cadence / on appear.
    @Published private(set) var usedGB: Double = 0
    @Published private(set) var appGB: Double = 0
    @Published private(set) var cachedGB: Double = 0
    @Published private(set) var compressedGB: Double = 0
    @Published private(set) var swapUsedGB: Double = 0
    /// 0…1 memory pressure, used to colour the usage bar.
    @Published private(set) var pressure: Double = 0

    /// Reclaim below this is "noise", reported as "already optimized" not "0 MB".
    private let meaningfulBytes: Double = 64 * 1024 * 1024 // 64 MB
    private let bytesPerGB: Double = 1_073_741_824

    private var resetWork: DispatchWorkItem?

    /// Grants silent (passwordless) `purge` once the user opts in. When enabled,
    /// we run `sudo -n /usr/sbin/purge` directly; otherwise we fall back to the
    /// interactive admin dialog so cleaning still works before any setup.
    private let privilege: PurgePrivilege

    init(privilege: PurgePrivilege) {
        self.privilege = privilege
    }

    private enum Outcome { case ok, cancelled, needsPermission, failed }

    /// Refresh the live breakdown. Synchronous, cheap, read-only — safe to call
    /// from the monitor tick or on view appear.
    func refresh() {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let used = Double(SystemMonitorService.usedMemoryBytes() ?? 0)
        usedGB = used / bytesPerGB
        appGB = Double(SystemMonitorService.appBytes() ?? 0) / bytesPerGB
        cachedGB = Double(SystemMonitorService.cachedBytes() ?? 0) / bytesPerGB
        compressedGB = Double(SystemMonitorService.compressedBytes() ?? 0) / bytesPerGB
        swapUsedGB = Double(SystemMonitorService.swapUsedBytes() ?? 0) / bytesPerGB
        pressure = total > 0 ? min(used / total, 1) : 0
    }

    func clean() {
        guard state != .cleaning else { return }
        resetWork?.cancel()
        state = .cleaning // instant feedback on the main thread

        let beforeUsed = SystemMonitorService.usedMemoryBytes() ?? 0
        // Capture the capability on the main thread; the published flag must not
        // be read from the background queue below.
        let passwordless = privilege.isPasswordless

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let outcome = self.runPurge(passwordless: passwordless)
            // Let the kernel settle so the counters reflect the flush.
            Thread.sleep(forTimeInterval: 0.4)
            let afterUsed = SystemMonitorService.usedMemoryBytes() ?? beforeUsed
            // "Freed" = the real reduction in Memory Used (active + wired +
            // compressed), matching Activity Monitor — NOT the free-list rise,
            // which `purge` inflates with reclaimable file cache that was never
            // counted as "used" in the first place.
            let freedBytes = max(0, Double(beforeUsed) - Double(afterUsed))
            let freedMB: Double? = freedBytes >= self.meaningfulBytes
                ? freedBytes / (1024 * 1024)
                : nil

            DispatchQueue.main.async {
                self.refresh() // update breakdown after the purge
                switch outcome {
                case .ok:
                    self.lastFreedMB = freedMB
                    self.lastUsedBeforeGB = Double(beforeUsed) / self.bytesPerGB
                    self.lastUsedAfterGB = Double(afterUsed) / self.bytesPerGB
                    self.state = .done
                case .cancelled:
                    self.state = .cancelled
                case .needsPermission:
                    self.state = .needsPermission
                case .failed:
                    self.state = .failed
                }
                // Hold the result long enough to read (the notch is pinned open
                // while cleaning + briefly after, see NotchViewModel).
                let work = DispatchWorkItem { [weak self] in self?.state = .idle }
                self.resetWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
            }
        }
    }

    // MARK: - Official purge

    /// Run `/usr/sbin/purge`, preferring the silent passwordless path when the
    /// user has opted in. Falls back to the interactive admin dialog if the
    /// sudoers rule is absent or has been revoked, so cleaning always works.
    private func runPurge(passwordless: Bool) -> Outcome {
        if passwordless, let outcome = runPurgeViaSudo() { return outcome }
        return runPurgeViaAdmin()
    }

    /// Run `sudo -n /usr/sbin/purge` with no prompt. Returns `.ok` on success,
    /// or `nil` when the passwordless rule didn't apply (so the caller falls back
    /// to the interactive dialog).
    private func runPurgeViaSudo() -> Outcome? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/usr/sbin/purge"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? .ok : nil
        } catch {
            return nil
        }
    }

    /// Run `/usr/sbin/purge` elevated through macOS's secure auth dialog.
    /// Mirrors `FocusService`'s NSAppleScript pattern; never blocks the main
    /// thread (called on a background queue). A user-cancel (-128) is treated
    /// gracefully; any other error means the auth/exec failed.
    private func runPurgeViaAdmin() -> Outcome {
        let source = "do shell script \"/usr/sbin/purge\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        script.executeAndReturnError(&error)
        guard let error else { return .ok }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        // -128 = user clicked Cancel on the auth dialog (userCancelledErr).
        if code == -128 { return .cancelled }
        return .needsPermission
    }
}
