import Combine
import Foundation

/// How much rebuildable cache is on disk, and the one action that moves the
/// safe part of it to the Trash.
///
/// Deliberately not the RAM cleaner this app removed in 0.2: nothing here
/// needs root, a helper, or a subprocess. It reads folders the user already
/// owns and moves them with `trashItem`, so every byte it touches can be put
/// back from the Trash.
///
/// The scan runs in one detached task at `.utility`. Every hand-back to the
/// main actor carries the generation it started with, so a scan the user
/// stopped — or one a newer scan replaced — can never write its answer over
/// the current one.
@MainActor
final class CacheCleanupService: ObservableObject {

    enum State: Equatable {
        /// Never scanned on this Mac, or the stored result was unusable.
        case unscanned
        /// A scan is walking the folders; the number is what it has counted so far.
        case scanning(bytesSoFar: Int64)
        /// Enough to be worth clearing.
        case ready(CacheScanSummary)
        /// Scanned, and there is nothing much to clear — a different fact from
        /// "not scanned yet", and it says so.
        case tidy(CacheScanSummary)
        case cleaning(itemCount: Int)
        /// Held briefly so the result can be read, then a rescan follows.
        case cleaned(CleanSummary)
        case failed(CleanupError)
    }

    /// Below this, a clean is not worth offering. The same 64 MB floor Purge
    /// uses for the one figure it will call reclaimed.
    nonisolated static let noiseFloorBytes: Int64 = 64 * 1024 * 1024
    /// How old a result may be before opening the panel refreshes it.
    nonisolated static let staleAfter: TimeInterval = 3600
    /// How long the result stands before the rescan replaces it.
    nonisolated static let resultHold: TimeInterval = 6

    @Published private(set) var state: State = .unscanned
    /// The last scan's rows, safe and check-first alike. The clean acts on the
    /// safe ones; the check-first count is only ever shown.
    @Published private(set) var candidates: [CacheCandidate] = []

    private let preferences: CleanupPreferences
    private let io: CacheCleanupIO
    private let home: URL
    private let now: @Sendable () -> Date
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Bumped by every scan, clean and stop. Work carries the number it began
    /// with and stands down if it is no longer current.
    private var generation = 0
    private var work: Task<Void, Never>?

    init(
        preferences: CleanupPreferences,
        io: CacheCleanupIO = .live,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        now: @escaping @Sendable () -> Date = { Date() },
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
            = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    ) {
        self.preferences = preferences
        self.io = io
        self.home = home
        self.now = now
        self.schedule = schedule
        if let stored = preferences.lastScan {
            state = Self.settled(stored)
        }
    }

    // MARK: - Entry points

    /// Called when the Focus panel appears. Cheap when the stored number is
    /// still good, which is most opens.
    func refreshIfStale() {
        guard preferences.showInFocus else { return }
        guard isStale(at: now()) else { return }
        scan()
    }

    func scan() {
        guard preferences.showInFocus else { return }
        switch state {
        case .scanning, .cleaning: return
        default: break
        }
        let plan = CacheScanPlan(
            home: home,
            includeDeveloperCaches: preferences.includeDeveloperCaches,
            includeContainers: io.fullDiskAccess()
        )
        generation += 1
        let generation = generation
        state = .scanning(bytesSoFar: 0)
        let io = io
        let now = now
        work?.cancel()
        work = Task.detached(priority: .utility) { [weak self] in
            let outcome = CacheCleanupEngine.scan(
                plan,
                io: io,
                isCancelled: { Task.isCancelled },
                progress: { bytes in
                    Task { @MainActor [weak self] in self?.absorbProgress(bytes, generation: generation) }
                },
                now: now()
            )
            await MainActor.run { [weak self] in
                self?.finishScan(outcome, plan: plan, generation: generation)
            }
        }
    }

    /// Move every safe row to the Trash. Check-first rows are never included,
    /// and the policy is asked again about each path on the way out.
    func cleanSafe() {
        guard case .ready = state else { return }
        let targets = candidates.filter { $0.level == .safe }
        guard !targets.isEmpty else { return }
        generation += 1
        let generation = generation
        state = .cleaning(itemCount: targets.count)
        let io = io
        let home = home
        let now = now
        work?.cancel()
        work = Task.detached(priority: .utility) { [weak self] in
            let outcome = CacheCleanupEngine.clean(
                targets, home: home, io: io, isCancelled: { Task.isCancelled }, now: now()
            )
            await MainActor.run { [weak self] in
                self?.finishClean(outcome, generation: generation)
            }
        }
    }

    /// Stand down. Any work in flight is cancelled and its answer discarded.
    func stop() {
        generation += 1
        work?.cancel()
        work = nil
        switch state {
        case .scanning, .cleaning:
            state = preferences.lastScan.map(Self.settled) ?? .unscanned
        default:
            break
        }
    }

    /// Whether the panel should scan when it next appears.
    func isStale(at moment: Date) -> Bool {
        switch state {
        case .scanning, .cleaning, .cleaned: return false
        case .unscanned, .failed: return true
        case let .ready(summary), let .tidy(summary):
            if summary.includedDeveloperCaches != preferences.includeDeveloperCaches { return true }
            if summary.includedContainers != io.fullDiskAccess() { return true }
            return moment.timeIntervalSince(summary.date) >= Self.staleAfter
        }
    }

    // MARK: - Completion

    private func absorbProgress(_ bytes: Int64, generation: Int) {
        guard generation == self.generation, case .scanning = state else { return }
        state = .scanning(bytesSoFar: bytes)
    }

    private func finishScan(_ outcome: CacheScanOutcome, plan: CacheScanPlan, generation: Int) {
        guard generation == self.generation else { return }
        work = nil
        if outcome.cancelled { return }
        if let failure = outcome.failure {
            state = .failed(failure)
            return
        }
        let safe = outcome.candidates.filter { $0.level == .safe }
        let checkFirst = outcome.candidates.filter { $0.level == .medium }
        let summary = CacheScanSummary(
            safeBytes: safe.reduce(0) { $0 + $1.bytes },
            safeCount: safe.count,
            checkFirstBytes: checkFirst.reduce(0) { $0 + $1.bytes },
            checkFirstCount: checkFirst.count,
            date: outcome.finishedAt,
            includedDeveloperCaches: plan.includeDeveloperCaches,
            includedContainers: plan.includeContainers
        )
        candidates = outcome.candidates
        preferences.recordScan(summary)
        state = Self.settled(summary)
    }

    private func finishClean(_ outcome: CleanOutcome, generation: Int) {
        guard generation == self.generation else { return }
        work = nil
        if outcome.cancelled { return }
        let summary = outcome.summary
        preferences.recordClean(summary)

        guard summary.movedCount > 0 else {
            state = .failed(.nothingMoved(
                attempted: outcome.attempted,
                reason: summary.firstFailure ?? "every folder was refused by the safety check"
            ))
            return
        }
        // Subtract what moved rather than wait for the rescan, so a quit
        // during the hold does not restore the pre-clean number on next launch.
        if let previous = preferences.lastScan {
            preferences.recordScan(previous.subtracting(summary))
        }
        candidates.removeAll { $0.level == .safe }
        state = .cleaned(summary)
        let held = generation
        schedule(Self.resultHold) {
            Task { @MainActor [weak self] in self?.endHold(generation: held) }
        }
    }

    private func endHold(generation: Int) {
        guard generation == self.generation, case .cleaned = state else { return }
        state = preferences.lastScan.map(Self.settled) ?? .unscanned
        scan()
    }

    private static func settled(_ summary: CacheScanSummary) -> State {
        summary.safeBytes >= noiseFloorBytes ? .ready(summary) : .tidy(summary)
    }
}
