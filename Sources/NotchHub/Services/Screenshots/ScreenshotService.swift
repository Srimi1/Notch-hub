import AppKit
import Foundation
import Observation

/// Puts every screenshot you take on the clipboard.
///
/// macOS saves a screenshot to a folder and, unless you hold Control while you
/// shoot, leaves the clipboard alone. This watches that folder and copies each
/// new screenshot as it lands, so ⌘V works straight away.
///
/// Three things keep it well-behaved:
///  - **It is off until asked for.** Turning it on is what opens the folder, so
///    the macOS permission dialog belongs to a button the user just pressed
///    rather than appearing at login from an app with no window.
///  - **It only ever opens files macOS has already tagged as screen captures.**
///    A file the user saved to their Desktop is never read.
///  - **It watches exactly one folder**, the one `screencapture` is configured
///    to write to, and re-reads that setting rather than assuming the Desktop.
@MainActor
@Observable
final class ScreenshotService {

    /// Spelled outside the class so it stays free of the main actor: the
    /// permission probe produces one off-actor and hands it back.
    typealias Access = ScreenshotAccess

    private(set) var access: Access = .unknown
    private(set) var location: ScreenshotLocation
    private(set) var lastError: String?
    /// Something worth saying that is not a failure — a format that cannot be
    /// copied, a screenshot too big to hold.
    private(set) var statusNote: String?

    var folderName: String { location.folderName }

    /// A screenshot has been read and is ready for the pasteboard.
    @ObservationIgnored var onCapture: ((CapturedScreenshot) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    /// How often the folder is re-read from scratch. This is the backstop for
    /// every way a directory event can be missed: a coalesced event, a stale
    /// watch after the folder was replaced underneath us, a save location
    /// changed in System Settings, which macOS announces to nobody.
    static let reconcileInterval: TimeInterval = 30

    @ObservationIgnored private let preferences: ScreenshotPreferences
    @ObservationIgnored private let watcher: any DirectoryWatching
    @ObservationIgnored private let readLocation: @Sendable () -> ScreenshotLocation
    @ObservationIgnored private let listDirectory: @Sendable (URL) throws -> [ScreenshotScanPolicy.Entry]
    @ObservationIgnored private let classify: @Sendable (URL) -> ScreenshotClassifier.Verdict
    @ObservationIgnored private let probe: @Sendable (URL) -> Access
    @ObservationIgnored private let trashItem: @Sendable (URL) throws -> Void
    @ObservationIgnored
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var armedFolder: URL?
    @ObservationIgnored private var cutoff = Date.distantPast
    @ObservationIgnored private var handledPaths: [String] = []
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var wantsRescan = false
    @ObservationIgnored private var retries: [URL: Int] = [:]
    @ObservationIgnored private let activationObserver: ObserverToken
    @ObservationIgnored private let wakeObserver: ObserverToken

    init(
        preferences: ScreenshotPreferences,
        watcher: any DirectoryWatching = DirectoryWatcher(),
        readLocation: @escaping @Sendable () -> ScreenshotLocation = { ScreenshotLocation.read() },
        listDirectory: @escaping @Sendable (URL) throws -> [ScreenshotScanPolicy.Entry]
            = ScreenshotService.contents(of:),
        classify: @escaping @Sendable (URL) -> ScreenshotClassifier.Verdict = {
            ScreenshotClassifier.classify(url: $0)
        },
        probe: @escaping @Sendable (URL) -> Access = ScreenshotService.probeAccess(to:),
        trashItem: @escaping @Sendable (URL) throws -> Void = ScreenshotService.moveToTrash(_:),
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.preferences = preferences
        self.watcher = watcher
        self.readLocation = readLocation
        self.listDirectory = listDirectory
        self.classify = classify
        self.probe = probe
        self.trashItem = trashItem
        self.schedule = schedule
        self.now = now
        location = readLocation()
        activationObserver = ObserverToken(center: NotificationCenter.default)
        wakeObserver = ObserverToken(center: NSWorkspace.shared.notificationCenter)
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        cutoff = now()

        // The timer is what `armWatch` reads as "this service is running", so
        // it has to exist before the first arm. Arming first left the watch
        // switched off until the first reconcile half a minute later — the
        // feature looked broken for thirty seconds after every launch.
        let timer = Timer(timeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observeReturns()
        refreshLocation()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher.stop()
        armedFolder = nil
        retries.removeAll()
        wantsRescan = false
    }

    // MARK: - Permission

    /// Opens the screenshot folder once, on purpose, which is what makes macOS
    /// put up its folder-permission dialog.
    ///
    /// Off the main actor deliberately: this call blocks until the user answers
    /// the dialog, and the notch panel is always on screen.
    func requestAccess() {
        location = readLocation()
        let folder = location.folder
        let probe = probe
        Task.detached(priority: .userInitiated) {
            let verdict = probe(folder)
            await MainActor.run { self.apply(verdict, for: folder) }
        }
    }

    private func apply(_ verdict: Access, for folder: URL) {
        access = verdict
        switch verdict {
        case .allowed:
            preferences.allow(folder)
            lastError = nil
            armWatch()
        case .denied:
            preferences.forget(folder)
            report("macOS is blocking access to \(folder.lastPathComponent). Allow NotchHub in "
                + "\(SystemSettingsPane.filesAndFolders.settingsPath), then turn this back on.")
        case .folderMissing:
            report("\(folder.path) does not exist, so there are no screenshots to watch.")
        case .unknown:
            break
        }
        onChange?()
    }

    // MARK: - Watching

    /// Re-reads where macOS is saving screenshots and re-arms if it moved.
    private func refreshLocation() {
        let resolved = readLocation()
        let moved = resolved.folder != location.folder
        location = resolved

        if moved {
            watcher.stop()
            armedFolder = nil
            lastError = nil
            access = preferences.isAllowed(resolved.folder) ? .allowed : .unknown
            retries.removeAll()
            cutoff = now()
        }
        statusNote = Self.formatNote(for: resolved.format)
        armWatch()
    }

    /// Only ever arms on a folder the user has already been asked about. That
    /// is the whole reason no dialog can appear at launch.
    private func armWatch() {
        guard timer != nil else { return }
        guard preferences.isAllowed(location.folder) else { return }
        let folder = location.folder
        guard armedFolder != folder else { return }
        armedFolder = folder
        access = .allowed
        watcher.start(folder) { [weak self] change in
            Task { @MainActor [weak self] in self?.handle(change) }
        }
        scan()
    }

    private func handle(_ change: DirectoryChange) {
        switch change {
        case .changed:
            scan()
        case .vanished:
            // The folder we were holding is gone. Drop the watch and let the
            // next reconcile re-arm by path, which is what picks a recreated
            // folder back up.
            watcher.stop()
            armedFolder = nil
        case .failed(let reason):
            armedFolder = nil
            access = .denied
            report("NotchHub could not watch \(location.folderName): \(reason)")
            onChange?()
        }
    }

    /// Re-reads where macOS is saving screenshots and catches up on anything
    /// the watch may have missed.
    ///
    /// Runs on a timer, when the app comes forward, and after the Mac wakes.
    /// There is no notification for a cross-process defaults change, and a
    /// directory event can be coalesced away, so this is the backstop that
    /// makes both survivable.
    func refresh() {
        refreshLocation()
        if armedFolder != nil { scan() }
    }

    private func observeReturns() {
        if activationObserver.isEmpty {
            activationObserver.value = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        if wakeObserver.isEmpty {
            wakeObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    // MARK: - Scanning

    private func scan() {
        guard let folder = armedFolder else { return }
        guard !isScanning else { wantsRescan = true; return }
        isScanning = true

        let started = now()
        let cutoff = cutoff
        let handled = Set(handledPaths)
        let list = listDirectory
        let classify = classify

        Task.detached(priority: .utility) {
            let outcome = Self.performScan(
                folder: folder, cutoff: cutoff, handled: handled, list: list, classify: classify
            )
            await MainActor.run { self.finish(outcome, startedAt: started) }
        }
    }

    /// Off the main actor: this lists a directory and reads files, both of
    /// which can block on iCloud, a slow volume, or a permission dialog.
    private nonisolated static func performScan(
        folder: URL,
        cutoff: Date,
        handled: Set<String>,
        list: @Sendable (URL) throws -> [ScreenshotScanPolicy.Entry],
        classify: @Sendable (URL) -> ScreenshotClassifier.Verdict
    ) -> ScanOutcome {
        var outcome = ScanOutcome()
        let entries: [ScreenshotScanPolicy.Entry]
        do {
            entries = try list(folder)
        } catch {
            outcome.failure = error.localizedDescription
            return outcome
        }
        for entry in ScreenshotScanPolicy.candidates(in: entries, newerThan: cutoff, excluding: handled) {
            outcome.absorb(classify(entry.url), at: entry.url)
        }
        return outcome
    }

    private func finish(_ outcome: ScanOutcome, startedAt started: Date) {
        isScanning = false
        cutoff = ScreenshotScanPolicy.nextCutoff(after: cutoff, scanStartedAt: started)

        if let failure = outcome.failure {
            access = Self.isPermissionFailure(failure) ? .denied : access
            report("NotchHub could not read \(location.folderName): \(failure)")
        }
        if let note = outcome.note { statusNote = note }
        for capture in outcome.captures { deliver(capture) }
        for url in outcome.retry { scheduleRetry(url) }

        if !outcome.captures.isEmpty || outcome.failure != nil || outcome.note != nil { onChange?() }
        if wantsRescan {
            wantsRescan = false
            scan()
        }
    }

    // MARK: - Retry

    /// A file that turned up before it was finished — or before macOS had
    /// tagged it — is looked at again on a short ladder, then dropped. Dropping
    /// is the common case: most files that appear are not screenshots, and
    /// re-examining them forever would keep the watch queue busy all session.
    private func scheduleRetry(_ url: URL) {
        let attempt = retries[url] ?? 0
        guard let delay = ScreenshotScanPolicy.retryDelay(attempt: attempt) else {
            retries[url] = nil
            return
        }
        retries[url] = attempt + 1
        schedule(delay) { Task { @MainActor [weak self] in self?.reclassify(url) } }
    }

    private func reclassify(_ url: URL) {
        guard retries[url] != nil else { return }
        let classify = classify
        Task.detached(priority: .utility) {
            let outcome = ScanOutcome(verdict: classify(url), at: url)
            await MainActor.run { self.finishRetry(outcome, for: url) }
        }
    }

    private func finishRetry(_ outcome: ScanOutcome, for url: URL) {
        if let capture = outcome.captures.first {
            retries[url] = nil
            deliver(capture)
            onChange?()
        } else if outcome.retry.isEmpty {
            retries[url] = nil
        } else {
            scheduleRetry(url)
        }
        if let note = outcome.note { statusNote = note }
    }

    // MARK: - Delivery

    private func deliver(_ capture: CapturedScreenshot) {
        let path = ScreenshotPreferences.identity(of: capture.url)
        guard !handledPaths.contains(path) else { return }
        handledPaths = ScreenshotScanPolicy.remembering(path, in: handledPaths)
        retries[capture.url] = nil
        lastError = nil

        onCapture?(capture)

        // Only ever after the copy has been handed over, and only ever to the
        // Trash — the picture is recoverable if any of this was a mistake.
        guard preferences.trashAfterCopying else { return }
        do {
            try trashItem(capture.url)
        } catch {
            report("NotchHub copied the screenshot but could not move it to the Trash: "
                + error.localizedDescription)
        }
    }

    private func report(_ message: String) {
        lastError = message
        NSLog("NotchHub screenshots: %@", message)
    }
}
