import EventKit
import Foundation
import Testing
@testable import NotchHub

@Suite("Next Up Coordinator")
struct ActivityCoordinatorTests {
    @Test
    @MainActor
    func urgentActivityPreemptsDuringDwell() {
        withPreferences { preferences in
            let coordinator = ActivityCoordinator(preferences: preferences, minimumDwell: 4)
            let start = Date(timeIntervalSince1970: 1_000)
            let media = snapshot(id: "media", kind: .media, priority: .foreground)
            let calendar = snapshot(id: "calendar", kind: .calendar, priority: .urgent)

            coordinator.submit([media], now: start)
            coordinator.submit([media, calendar], now: start.addingTimeInterval(1))

            #expect(coordinator.currentActivity?.id == "calendar")
        }
    }

    @Test
    @MainActor
    func equalPriorityWaitsForDwellThenUsesDateAndStableID() {
        withPreferences { preferences in
            let coordinator = ActivityCoordinator(preferences: preferences, minimumDwell: 4)
            let start = Date(timeIntervalSince1970: 2_000)
            let later = snapshot(
                id: "b",
                kind: .reminder,
                priority: .timeSensitive,
                date: start.addingTimeInterval(120)
            )
            let sooner = snapshot(
                id: "a",
                kind: .calendar,
                priority: .timeSensitive,
                date: start.addingTimeInterval(60)
            )

            coordinator.submit([later], now: start)
            coordinator.submit([later, sooner], now: start.addingTimeInterval(1))
            #expect(coordinator.currentActivity?.id == "b")

            coordinator.submit([later, sooner], now: start.addingTimeInterval(5))
            #expect(coordinator.currentActivity?.id == "a")
            #expect(coordinator.queue.map(\.id) == ["a", "b"])
        }
    }

    @Test
    @MainActor
    func disabledKindsAreRemovedAndMediaCanBePinned() {
        withPreferences { preferences in
            let coordinator = ActivityCoordinator(preferences: preferences, minimumDwell: 0)
            let media = snapshot(id: "media", kind: .media, priority: .foreground)
            let urgent = snapshot(id: "urgent", kind: .calendar, priority: .urgent)

            preferences.setEnabled(.calendar, enabled: false)
            coordinator.submit([media, urgent])
            #expect(coordinator.queue.map(\.id) == ["media"])

            preferences.setEnabled(.calendar, enabled: true)
            preferences.urgentOverridesMedia = false
            coordinator.submit([media, urgent])
            #expect(coordinator.currentActivity?.id == "media")
        }
    }

    @Test
    func activityActionsAreCappedAtTwo() {
        let value = ActivitySnapshot(
            id: "x",
            kind: .calendar,
            priority: .normal,
            title: "Meeting",
            detail: "Soon",
            actions: [.openCalendar, .navigate(.calendar), .navigate(.dashboard)]
        )
        #expect(value.actions.count == 2)
    }

    @Test
    @MainActor
    func disablingEveryActivityPersistsAsEmpty() {
        let suite = "ActivityPreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ActivityPreferences(defaults: defaults)
        for kind in ActivityKind.allCases {
            preferences.setEnabled(kind, enabled: false)
        }

        let restored = ActivityPreferences(defaults: defaults)
        #expect(restored.enabledKinds.isEmpty)
    }

    private func snapshot(
        id: String,
        kind: ActivityKind,
        priority: ActivityPriority,
        date: Date? = nil
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: id,
            kind: kind,
            priority: priority,
            title: id,
            detail: "detail",
            relevanceDate: date
        )
    }

    @MainActor
    private func withPreferences(_ body: (ActivityPreferences) -> Void) {
        let suite = "ActivityCoordinatorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(ActivityPreferences(defaults: defaults))
    }
}

// URL-safety coverage lives in `UntrustedInputTests.swift` alongside the rest of
// the hostile-input guards.

/// The headline feature used to be permanently hijacked by whatever reminder
/// you had forgotten longest. Everything here is about keeping "Next Up"
/// pointed at what actually happens next.
@Suite("Next Up is not hijacked by stale reminders")
struct ReminderRankingTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminder(_ id: String, dueIn seconds: TimeInterval) -> ReminderRecord {
        ReminderRecord(id: id, title: "Task \(id)", dueDate: now.addingTimeInterval(seconds))
    }

    /// A task forgotten years ago is backlog. It must not appear at all.
    @Test
    func ancientOverdueRemindersAreDroppedEntirely() {
        let ancient = reminder("ancient", dueIn: -365 * 24 * 60 * 60)
        let yesterday = reminder("yesterday", dueIn: -48 * 60 * 60)
        let recent = reminder("recent", dueIn: -30 * 60)

        let snapshots = ActivitySnapshotFactory.reminders(
            [ancient, yesterday, recent], now: now, leadMinutes: 30
        )

        #expect(snapshots.map(\.id) == ["reminder.recent"])
    }

    /// The tie-break that caused the hijack: equal priority resolves on the
    /// *earliest* relevance date, so an overdue reminder beat everything.
    /// Something late since this morning must no longer outrank a meeting
    /// starting in three minutes.
    @Test
    @MainActor
    func anImminentMeetingOutranksAReminderThatIsMerelyLate() {
        let lateReminder = reminder("late", dueIn: -3 * 60 * 60)
        let reminderSnapshots = ActivitySnapshotFactory.reminders(
            [lateReminder], now: now, leadMinutes: 30
        )
        let event = CalendarService.Event(
            id: "standup",
            title: "Standup",
            start: now.addingTimeInterval(180),
            end: now.addingTimeInterval(1_800),
            isAllDay: false,
            calendarColorHex: nil,
            location: nil,
            url: nil
        )
        let eventSnapshots = ActivitySnapshotFactory.calendar(
            events: [event], now: now, leadMinutes: 15
        )

        #expect(reminderSnapshots.first?.priority == .timeSensitive)
        #expect(eventSnapshots.first?.priority == .urgent)
        #expect(
            (eventSnapshots.first?.priority.rawValue ?? 0)
                > (reminderSnapshots.first?.priority.rawValue ?? 0),
            "A meeting in three minutes must outrank a task late since this morning."
        )
    }

    /// A miss from moments ago genuinely is the thing to do right now.
    @Test
    func aFreshlyMissedReminderIsStillUrgent() {
        let snapshots = ActivitySnapshotFactory.reminders(
            [reminder("fresh", dueIn: -5 * 60)], now: now, leadMinutes: 30
        )
        #expect(snapshots.first?.priority == .urgent)
        #expect(snapshots.first?.detail == "Overdue by 5m")
    }

    /// The notch used to literally read "Overdue by 56184h".
    @Test
    func longDurationsReadInDaysNotHundredsOfHours() {
        #expect(ActivitySnapshotFactory.shortDuration(90 * 60) == "1h 30m")
        #expect(ActivitySnapshotFactory.shortDuration(24 * 60 * 60) == "1d")
        #expect(ActivitySnapshotFactory.shortDuration(51 * 60 * 60) == "2d 3h")
        #expect(ActivitySnapshotFactory.shortDuration(30) == "under a minute")
    }
}

@Suite("Activity Providers")
struct ActivitySnapshotFactoryTests {
    @Test
    func calendarCandidateUsesLeadWindowAndSafeActions() {
        let now = Date(timeIntervalSince1970: 10_000)
        let event = CalendarService.Event(
            id: "event",
            title: "Design review",
            start: now.addingTimeInterval(240),
            end: now.addingTimeInterval(3_600),
            isAllDay: false,
            calendarColorHex: nil,
            location: "Cupertino",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )

        let candidates = ActivitySnapshotFactory.calendar(events: [event], now: now, leadMinutes: 15)

        #expect(candidates.count == 1)
        #expect(candidates.first?.priority == .urgent)
        #expect(candidates.first?.actions.count == 2)
        let meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")
        #expect(candidates.first?.actions.first == meetingURL.map(ActivityAction.joinMeeting))
    }

    @Test
    func allDayAndDistantEventsAreNotSurfaced() {
        let now = Date(timeIntervalSince1970: 20_000)
        let distant = CalendarService.Event(
            id: "distant",
            title: "Later",
            start: now.addingTimeInterval(7_200),
            end: now.addingTimeInterval(8_000),
            isAllDay: false,
            calendarColorHex: nil,
            location: nil,
            url: nil
        )
        let allDay = CalendarService.Event(
            id: "all-day",
            title: "Holiday",
            start: now,
            end: now.addingTimeInterval(86_400),
            isAllDay: true,
            calendarColorHex: nil,
            location: nil,
            url: nil
        )

        #expect(ActivitySnapshotFactory.calendar(events: [distant, allDay], now: now, leadMinutes: 15).isEmpty)
    }

    @Test
    func lowBatteryBecomesUrgentAndChargingStaysAmbient() {
        let low = ActivitySnapshotFactory.battery(
            hasBattery: true,
            percent: 15,
            isCharging: false,
            isCharged: false,
            minutesRemaining: 30,
            warningPercent: 20
        )
        let charging = ActivitySnapshotFactory.battery(
            hasBattery: true,
            percent: 15,
            isCharging: true,
            isCharged: false,
            minutesRemaining: 45,
            warningPercent: 20
        )

        #expect(low?.priority == .urgent)
        #expect(charging?.priority == .ambient)
        #expect(ActivitySnapshotFactory.battery(
            hasBattery: false,
            percent: 0,
            isCharging: false,
            isCharged: false,
            minutesRemaining: nil,
            warningPercent: 20
        ) == nil)
    }
}
