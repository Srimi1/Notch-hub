@preconcurrency import EventKit
import Foundation
import Observation

struct ReminderRecord: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let dueDate: Date?
}

enum ReminderAccess: Equatable, Sendable {
    case unknown
    case granted
    case denied
}

enum ReminderServiceError: LocalizedError {
    case accessDenied
    case fetchFailed
    case reminderNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Reminders access is disabled in System Settings."
        case .fetchFailed: "NotchHub could not load reminders."
        case .reminderNotFound: "That reminder is no longer available."
        }
    }
}

@MainActor
protocol ReminderStoreProtocol: AnyObject {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    func fetchIncomplete() async throws -> [ReminderRecord]
    func complete(id: String) async throws
}

@MainActor
final class EventKitReminderStore: ReminderStoreProtocol {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            if #available(macOS 14, *) {
                store.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            } else {
                store.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    func fetchIncomplete() async throws -> [ReminderRecord] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: Calendar.current.date(byAdding: .day, value: 2, to: .now),
            calendars: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: ReminderServiceError.fetchFailed)
                    return
                }
                let mapped = reminders.prefix(50).map { reminder in
                    ReminderRecord(
                        id: reminder.calendarItemIdentifier,
                        title: DisplaySanitizer.text(reminder.title, limit: 120),
                        dueDate: reminder.dueDateComponents?.date
                    )
                }
                continuation.resume(returning: mapped)
            }
        }
    }

    func complete(id: String) async throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound
        }
        reminder.isCompleted = true
        reminder.completionDate = .now
        try store.save(reminder, commit: true)
    }
}

@MainActor
@Observable
final class ReminderService {
    private(set) var access: ReminderAccess = .unknown
    private(set) var reminders: [ReminderRecord] = []
    private(set) var lastError: String?

    @ObservationIgnored private let store: ReminderStoreProtocol
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var lastKnownStatus: EKAuthorizationStatus?
    /// Monotonic reload token: only the newest fetch may publish its result.
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var tombstones = CompletionTombstones()
    @ObservationIgnored var onChange: (() -> Void)?

    convenience init() {
        self.init(store: EventKitReminderStore())
    }

    init(store: ReminderStoreProtocol) {
        self.store = store
    }

    func start() {
        refreshAuthorization()
        guard refreshTimer == nil else { return }
        // Re-read the authorization status on every tick: macOS posts no
        // notification when the user flips the Reminders switch in System
        // Settings, and without this a grant needed an app relaunch.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAuthorization()
                self?.reload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func requestAccess() async {
        do {
            let granted = try await store.requestAccess()
            access = granted ? .granted : .denied
            if granted {
                await reloadNow()
            } else {
                report(ReminderServiceError.accessDenied)
            }
        } catch {
            access = .denied
            report(error)
        }
        lastKnownStatus = store.authorizationStatus
        onChange?()
    }

    /// Re-reads the live EventKit status and reacts to a change made outside the
    /// app (System Settings → Privacy & Security → Reminders).
    func refreshAuthorization() {
        let status = store.authorizationStatus
        guard status != lastKnownStatus else { return }
        lastKnownStatus = status

        switch EventKitAccessDecision.decide(for: status) {
        case .granted:
            access = .granted
            lastError = nil
            reload()
        case .denied:
            access = .denied
            reminders = []
            // Overwrite whatever the last fetch said. "NotchHub could not load
            // reminders" is misleading once the real reason is that access was
            // switched off in System Settings.
            report(ReminderServiceError.accessDenied)
        case .needsPrompt:
            access = .unknown
            lastError = nil
        }
        onChange?()
    }

    @discardableResult
    func complete(id: String) async -> Bool {
        do {
            try await store.complete(id: id)
            // Tombstone before publishing: a fetch that started before this
            // write will still list the reminder as incomplete, and must not be
            // allowed to put it back on screen. Recording the current reload
            // generation is what keeps that suppression narrow — only queries
            // that predate the write are affected.
            tombstones.insert(id, generation: reloadGeneration)
            reminders.removeAll { $0.id == id }
            lastError = nil
            onChange?()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func reload() {
        Task { @MainActor [weak self] in
            await self?.reloadNow()
        }
    }

    func clearError() {
        lastError = nil
    }

    /// Awaitable form of `reload()`. Internal so tests can drive the
    /// in-flight-fetch ordering deterministically.
    func reloadNow() async {
        guard access == .granted else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let fetched = try await store.fetchIncomplete()
            // A newer reload published while this one was in flight — its data
            // is strictly fresher, so drop this result rather than rewind.
            guard generation == reloadGeneration, access == .granted else { return }
            reminders = fetched
                .filter { !tombstones.suppresses($0.id, forGeneration: generation) }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            // This fetch started after those completions, so it already
            // reflects them and the tombstones have served their purpose. Not
            // dropping them would permanently hide a reminder the user
            // un-completed in Reminders.app.
            tombstones.pruneResolved(upTo: generation)
            lastError = nil
        } catch {
            // A fetch that was already running when access was revoked must not
            // overwrite the access-denied message with a vaguer one.
            guard generation == reloadGeneration, access == .granted else { return }
            report(error)
        }
        onChange?()
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        NSLog("NotchHub reminders: %@", message)
        onChange?()
    }
}

/// Reminder ids completed locally but possibly still listed as incomplete by an
/// EventKit fetch that started before the write.
///
/// Each id remembers the reload generation current at completion time, and a
/// fetch suppresses the id **only** when the completion was recorded at or after
/// that fetch began — i.e. when the query provably predates the write. Once a
/// later fetch has run, the tombstone is dropped.
///
/// That narrowness is the point. Suppressing an id "until the store stops
/// reporting it" would look correct but would permanently hide a reminder the
/// user un-completed in Reminders.app: every subsequent fetch would list it and
/// every subsequent filter would remove it.
///
/// Insertion-ordered and hard-capped so a long stretch of failing reloads (which
/// never prune) cannot let it grow without bound.
struct CompletionTombstones {
    private var order: [String] = []
    private var generations: [String: Int] = [:]
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = max(1, limit)
    }

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }

    /// True when a fetch numbered `generation` may predate `id`'s completion.
    func suppresses(_ id: String, forGeneration generation: Int) -> Bool {
        guard let completedAt = generations[id] else { return false }
        return completedAt >= generation
    }

    mutating func insert(_ id: String, generation: Int) {
        if generations.updateValue(generation, forKey: id) == nil {
            order.append(id)
        }
        while order.count > limit {
            generations.removeValue(forKey: order.removeFirst())
        }
    }

    /// Drops tombstones that a fetch started after the completion has already
    /// accounted for.
    mutating func pruneResolved(upTo generation: Int) {
        let resolved = Set(order.filter { (generations[$0] ?? Int.max) < generation })
        guard !resolved.isEmpty else { return }
        order.removeAll { resolved.contains($0) }
        for id in resolved { generations.removeValue(forKey: id) }
    }
}
