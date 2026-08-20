import EventKit
import Foundation
import Testing
@testable import NotchHub

@MainActor
private final class TimerNotificationSpy: TimerNotificationScheduling {
    private(set) var scheduledIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []

    func schedule(id: UUID, title: String, endDate: Date) async throws {
        scheduledIDs.append(id)
    }

    func cancel(id: UUID) {
        cancelledIDs.append(id)
    }
}

@MainActor
private final class DelayedTimerNotificationSpy: TimerNotificationScheduling {
    private(set) var scheduledIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var installedIDs: Set<UUID> = []
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func schedule(id: UUID, title: String, endDate: Date) async throws {
        scheduledIDs.append(id)
        await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
        installedIDs.insert(id)
    }

    func cancel(id: UUID) {
        cancelledIDs.append(id)
        installedIDs.remove(id)
    }

    func finishScheduling(id: UUID) {
        continuations.removeValue(forKey: id)?.resume()
    }
}

@MainActor
private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@Suite("Persistent Timers")
struct ActivityTimerServiceTests {
    @Test
    @MainActor
    func timerCompletesAfterSleepAndRestoresAfterRelaunch() async {
        let suite = "ActivityTimerServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(Date(timeIntervalSince1970: 30_000))
        let notifications = TimerNotificationSpy()
        let service = ActivityTimerService(
            defaults: defaults,
            notifications: notifications,
            now: { clock.date }
        )
        let id = service.create(title: "Focus", duration: 60)
        await Task.yield()
        #expect(id != nil)
        #expect(notifications.scheduledIDs == id.map { [$0] })

        clock.date = clock.date.addingTimeInterval(3_600)
        service.tick()
        #expect(service.timers.first?.status == .completed)

        let restored = ActivityTimerService(
            defaults: defaults,
            notifications: TimerNotificationSpy(),
            now: { clock.date }
        )
        #expect(restored.timers.first?.id == id)
        #expect(restored.timers.first?.status == .completed)
    }

    @Test
    @MainActor
    func pauseResumeAndCancelPreserveRemainingTime() async {
        await withTimerService { service, clock, notifications in
            guard let id = service.create(title: "Break", duration: 600) else {
                Issue.record("Timer creation failed")
                return
            }
            clock.date = clock.date.addingTimeInterval(120)
            service.pause(id: id)
            #expect(service.timers.first?.status == .paused)
            #expect(service.timers.first?.remaining(at: clock.date) == 480)
            #expect(notifications.cancelledIDs.contains(id))

            service.resume(id: id)
            #expect(service.timers.first?.status == .running)
            #expect(service.timers.first?.endDate == clock.date.addingTimeInterval(480))

            service.cancel(id: id)
            #expect(service.timers.isEmpty)
        }
    }

    @Test
    @MainActor
    func invalidDurationsFailVisibly() async {
        await withTimerService { service, _, _ in
            #expect(service.create(title: "Too short", duration: 10) == nil)
            #expect(service.lastError == ActivityTimerError.invalidDuration.localizedDescription)
        }
    }

    @Test
    @MainActor
    func cancellingDuringNotificationSchedulingCannotLeaveGhostAlert() async {
        let suite = "ActivityTimerServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let notifications = DelayedTimerNotificationSpy()
        let service = ActivityTimerService(
            defaults: defaults,
            notifications: notifications,
            now: { Date(timeIntervalSince1970: 50_000) }
        )
        guard let id = service.create(title: "Cancel me", duration: 600) else {
            Issue.record("Timer creation failed")
            return
        }
        while notifications.scheduledIDs.isEmpty { await Task.yield() }

        service.cancel(id: id)
        notifications.finishScheduling(id: id)
        await Task.yield()
        await Task.yield()

        #expect(service.timers.isEmpty)
        #expect(notifications.installedIDs.isEmpty)
        #expect(notifications.cancelledIDs.filter { $0 == id }.count == 2)
    }

    @MainActor
    private func withTimerService(
        _ body: (ActivityTimerService, TestClock, TimerNotificationSpy) async -> Void
    ) async {
        let suite = "ActivityTimerServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Date(timeIntervalSince1970: 40_000))
        let notifications = TimerNotificationSpy()
        let service = ActivityTimerService(
            defaults: defaults,
            notifications: notifications,
            now: { clock.date }
        )
        await body(service, clock, notifications)
    }
}

@MainActor
private final class ReminderStoreFake: ReminderStoreProtocol {
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var requestGranted = true
    var records: [ReminderRecord] = []
    var completionError: Error?
    var fetchError: Error?

    /// When set, the next fetch snapshots the store and then blocks, modelling
    /// an EventKit query that ran *before* a completion was written.
    var pauseNextFetch = false
    private(set) var fetchGate: CheckedContinuation<Void, Never>?

    func requestAccess() async throws -> Bool {
        authorizationStatus = requestGranted ? .fullAccess : .denied
        return requestGranted
    }

    func fetchIncomplete() async throws -> [ReminderRecord] {
        let snapshot = records
        if pauseNextFetch {
            pauseNextFetch = false
            await withCheckedContinuation { continuation in
                fetchGate = continuation
            }
        }
        if let fetchError { throw fetchError }
        return snapshot
    }

    func releaseFetch() {
        let gate = fetchGate
        fetchGate = nil
        gate?.resume()
    }

    func complete(id: String) async throws {
        if let completionError { throw completionError }
        guard records.contains(where: { $0.id == id }) else {
            throw ReminderServiceError.reminderNotFound
        }
        records.removeAll { $0.id == id }
    }
}

private enum ReminderTestError: LocalizedError {
    case simulatedOffline

    var errorDescription: String? { "Simulated offline failure" }
}

@Suite("Reminders")
struct ReminderServiceTests {
    @Test
    @MainActor
    func grantedAccessLoadsAndCompletesReminder() async {
        let store = ReminderStoreFake()
        store.records = [ReminderRecord(id: "1", title: "Ship build", dueDate: .now)]
        let service = ReminderService(store: store)

        await service.requestAccess()
        #expect(service.access == .granted)
        #expect(service.reminders.map(\.id) == ["1"])
        #expect(await service.complete(id: "1"))
        #expect(service.reminders.isEmpty)
        #expect(service.lastError == nil)
    }

    @Test
    @MainActor
    func deniedAccessFailsVisiblyWithoutLoadingData() async {
        let store = ReminderStoreFake()
        store.requestGranted = false
        let service = ReminderService(store: store)

        await service.requestAccess()
        #expect(service.access == .denied)
        #expect(service.reminders.isEmpty)
        #expect(service.lastError == ReminderServiceError.accessDenied.localizedDescription)
    }

    /// An EventKit query that started before a completion still reports the
    /// reminder as incomplete. Publishing that snapshot would put a task the
    /// user just ticked off back on screen.
    @Test
    @MainActor
    func inFlightFetchCannotResurrectACompletedReminder() async {
        let store = ReminderStoreFake()
        store.records = [
            ReminderRecord(id: "1", title: "Ship build", dueDate: .now),
            ReminderRecord(id: "2", title: "Write notes", dueDate: .now)
        ]
        let service = ReminderService(store: store)
        await service.requestAccess()
        #expect(service.reminders.map(\.id) == ["1", "2"])

        store.pauseNextFetch = true
        let staleReload = Task { await service.reloadNow() }
        while store.fetchGate == nil { await Task.yield() }

        #expect(await service.complete(id: "1"))
        #expect(service.reminders.map(\.id) == ["2"])

        store.releaseFetch()
        await staleReload.value

        #expect(service.reminders.map(\.id) == ["2"])
    }

    /// The mirror image of the test above: suppression must be *narrow*. If the
    /// user un-completes the reminder in Reminders.app, the next fetch is
    /// authoritative and it has to come back — a tombstone that outlived its
    /// fetch would hide the reminder forever.
    @Test
    @MainActor
    func unCompletingElsewhereBringsTheReminderBack() async {
        let store = ReminderStoreFake()
        store.records = [ReminderRecord(id: "1", title: "Ship build", dueDate: .now)]
        let service = ReminderService(store: store)
        await service.requestAccess()

        #expect(await service.complete(id: "1"))
        #expect(service.reminders.isEmpty)

        // The user un-ticks it in Reminders.app before the next refresh tick.
        store.records = [ReminderRecord(id: "1", title: "Ship build", dueDate: .now)]
        await service.reloadNow()
        #expect(service.reminders.map(\.id) == ["1"])

        // …and it stays back on every later reload.
        await service.reloadNow()
        #expect(service.reminders.map(\.id) == ["1"])
    }

    /// Two overlapping reloads: only the newest may publish, so the UI never
    /// rewinds to an older snapshot.
    @Test
    @MainActor
    func anOlderReloadNeverOverwritesANewerOne() async {
        let store = ReminderStoreFake()
        store.records = [ReminderRecord(id: "old", title: "Old snapshot", dueDate: .now)]
        let service = ReminderService(store: store)
        await service.requestAccess()

        store.pauseNextFetch = true
        let slowReload = Task { await service.reloadNow() }
        while store.fetchGate == nil { await Task.yield() }

        store.records = [ReminderRecord(id: "new", title: "New snapshot", dueDate: .now)]
        await service.reloadNow()
        #expect(service.reminders.map(\.id) == ["new"])

        store.releaseFetch()
        await slowReload.value
        #expect(service.reminders.map(\.id) == ["new"])
    }

    /// macOS never tells the app that its Reminders switch changed, so the
    /// status is re-read. Without this, a grant needed an app relaunch.
    @Test
    @MainActor
    func accessGrantedInSystemSettingsRecoversWithoutRelaunch() async {
        let store = ReminderStoreFake()
        store.authorizationStatus = .denied
        let service = ReminderService(store: store)

        service.refreshAuthorization()
        #expect(service.access == .denied)
        #expect(service.reminders.isEmpty)

        store.authorizationStatus = .fullAccess
        store.records = [ReminderRecord(id: "1", title: "Ship build", dueDate: .now)]
        service.refreshAuthorization()
        await service.reloadNow()

        #expect(service.access == .granted)
        #expect(service.reminders.map(\.id) == ["1"])
        #expect(service.lastError == nil)
    }

    @Test
    @MainActor
    func accessRevokedInSystemSettingsClearsStaleReminders() async {
        let store = ReminderStoreFake()
        store.records = [ReminderRecord(id: "1", title: "Ship build", dueDate: .now)]
        let service = ReminderService(store: store)
        await service.requestAccess()
        #expect(service.reminders.map(\.id) == ["1"])

        store.authorizationStatus = .denied
        service.refreshAuthorization()

        #expect(service.access == .denied)
        #expect(service.reminders.isEmpty)
        #expect(service.lastError == ReminderServiceError.accessDenied.localizedDescription)
    }

    /// A fetch failure followed by a revocation must not leave the vaguer
    /// message on screen — "NotchHub could not load reminders" sends the user
    /// looking for a bug when the real fix is a switch in System Settings.
    @Test
    @MainActor
    func revocationReplacesAnEarlierFetchError() async {
        let store = ReminderStoreFake()
        let service = ReminderService(store: store)
        await service.requestAccess()

        store.fetchError = ReminderServiceError.fetchFailed
        await service.reloadNow()
        #expect(service.lastError == ReminderServiceError.fetchFailed.localizedDescription)

        store.authorizationStatus = .denied
        service.refreshAuthorization()

        #expect(service.lastError == ReminderServiceError.accessDenied.localizedDescription)
    }

    /// The same, but for a fetch that was already in flight when access was
    /// revoked and only fails afterwards.
    @Test
    @MainActor
    func lateFetchFailureDoesNotMaskTheAccessDeniedReason() async {
        let store = ReminderStoreFake()
        let service = ReminderService(store: store)
        await service.requestAccess()

        store.fetchError = ReminderServiceError.fetchFailed
        store.pauseNextFetch = true
        let inFlight = Task { await service.reloadNow() }
        while store.fetchGate == nil { await Task.yield() }

        store.authorizationStatus = .denied
        service.refreshAuthorization()
        store.releaseFetch()
        await inFlight.value

        #expect(service.access == .denied)
        #expect(service.lastError == ReminderServiceError.accessDenied.localizedDescription)
    }

    @Test
    @MainActor
    func completionFailureKeepsReminderAndReportsError() async {
        let store = ReminderStoreFake()
        store.records = [ReminderRecord(id: "2", title: "Retry me", dueDate: .now)]
        store.completionError = ReminderTestError.simulatedOffline
        let service = ReminderService(store: store)

        await service.requestAccess()
        #expect(await service.complete(id: "2") == false)
        #expect(service.reminders.map(\.id) == ["2"])
        #expect(service.lastError == "Simulated offline failure")
    }
}
