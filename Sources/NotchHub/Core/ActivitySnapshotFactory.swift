import Foundation

enum ActivitySnapshotFactory {
    static func calendar(
        events: [CalendarService.Event],
        now: Date,
        leadMinutes: Int
    ) -> [ActivitySnapshot] {
        let leadDate = now.addingTimeInterval(TimeInterval(leadMinutes * 60))
        return events
            .filter { !$0.isAllDay && $0.end > now && $0.start <= leadDate }
            .prefix(3)
            .map { event in
                let isOngoing = event.start <= now
                let seconds = isOngoing ? event.end.timeIntervalSince(now) : event.start.timeIntervalSince(now)
                let priority: ActivityPriority = isOngoing || seconds <= 300 ? .urgent : .timeSensitive
                var actions: [ActivityAction] = []
                if let url = SafeExternalURL.meetingURL(event.url) {
                    actions.append(.joinMeeting(url))
                }
                if let location = event.location, SafeExternalURL.mapsURL(for: location) != nil {
                    actions.append(.openLocation(location))
                }
                actions.append(.openCalendar)

                return ActivitySnapshot(
                    id: "calendar.\(event.id)",
                    kind: .calendar,
                    priority: priority,
                    title: event.title,
                    detail: isOngoing
                        ? "Ends in \(shortDuration(seconds))"
                        : "Starts in \(shortDuration(seconds))",
                    relevanceDate: event.start,
                    actions: actions
                )
            }
    }

    static func reminders(
        _ reminders: [ReminderRecord],
        now: Date,
        leadMinutes: Int
    ) -> [ActivitySnapshot] {
        let leadDate = now.addingTimeInterval(TimeInterval(leadMinutes * 60))
        return reminders
            .filter { reminder in
                guard let dueDate = reminder.dueDate else { return false }
                return dueDate <= leadDate
            }
            .prefix(3)
            .map { reminder in
                let dueDate = reminder.dueDate ?? now
                let delta = dueDate.timeIntervalSince(now)
                let detail: String
                let priority: ActivityPriority
                if delta <= 0 {
                    detail = "Overdue by \(shortDuration(abs(delta)))"
                    priority = .urgent
                } else {
                    detail = "Due in \(shortDuration(delta))"
                    priority = delta <= 300 ? .urgent : .timeSensitive
                }
                return ActivitySnapshot(
                    id: "reminder.\(reminder.id)",
                    kind: .reminder,
                    priority: priority,
                    title: reminder.title.isEmpty ? "Untitled reminder" : reminder.title,
                    detail: detail,
                    relevanceDate: dueDate,
                    actions: [.completeReminder(reminder.id), .navigate(.todo)]
                )
            }
    }

    static func timers(_ timers: [ActivityTimerRecord], now: Date) -> [ActivitySnapshot] {
        timers.map { timer in
            let remaining = timer.remaining(at: now)
            switch timer.status {
            case .completed:
                return ActivitySnapshot(
                    id: "timer.\(timer.id.uuidString)",
                    kind: .timer,
                    priority: .critical,
                    title: timer.title,
                    detail: "Timer complete",
                    relevanceDate: timer.completedAt,
                    actions: [.dismissTimer(timer.id), .navigate(.pomodoro)]
                )
            case .paused:
                return ActivitySnapshot(
                    id: "timer.\(timer.id.uuidString)",
                    kind: .timer,
                    priority: .normal,
                    title: timer.title,
                    detail: "Paused · \(clockDuration(remaining)) remaining",
                    relevanceDate: nil,
                    actions: [.resumeTimer(timer.id), .cancelTimer(timer.id)]
                )
            case .running:
                return ActivitySnapshot(
                    id: "timer.\(timer.id.uuidString)",
                    kind: .timer,
                    priority: remaining <= 60 ? .urgent : .timeSensitive,
                    title: timer.title,
                    detail: "\(clockDuration(remaining)) remaining",
                    relevanceDate: timer.endDate,
                    actions: [.pauseTimer(timer.id), .cancelTimer(timer.id)]
                )
            }
        }
    }

    static func battery(
        hasBattery: Bool,
        percent: Int,
        isCharging: Bool,
        isCharged: Bool,
        minutesRemaining: Int?,
        warningPercent: Int
    ) -> ActivitySnapshot? {
        guard hasBattery else { return nil }
        let priority: ActivityPriority
        if !isCharging, percent <= 10 {
            priority = .critical
        } else if !isCharging, percent <= warningPercent {
            priority = .urgent
        } else {
            priority = .ambient
        }

        let detail: String
        if isCharged {
            detail = "Fully charged"
        } else if isCharging {
            detail = minutesRemaining.map { "\(shortDuration(TimeInterval($0 * 60))) until full" }
                ?? "Charging"
        } else {
            detail = minutesRemaining.map { "\(shortDuration(TimeInterval($0 * 60))) remaining" }
                ?? "On battery power"
        }

        return ActivitySnapshot(
            id: "battery.current",
            kind: .battery,
            priority: priority,
            title: "Battery \(percent)%",
            detail: detail,
            symbol: isCharging || isCharged ? "battery.100.bolt" : batterySymbol(percent: percent),
            actions: [.navigate(.dashboard)]
        )
    }

    static func media(_ nowPlaying: MediaService.NowPlaying?, isPlaying: Bool) -> ActivitySnapshot? {
        guard let nowPlaying else { return nil }
        let artist = nowPlaying.artist.isEmpty ? nowPlaying.app.rawValue : nowPlaying.artist
        return ActivitySnapshot(
            id: "media.current",
            kind: .media,
            priority: .foreground,
            title: nowPlaying.title,
            detail: artist,
            symbol: isPlaying ? "waveform" : "pause.fill",
            actions: [.toggleMedia, .navigate(.media)]
        )
    }

    static func focus(isOn: Bool) -> ActivitySnapshot? {
        guard isOn else { return nil }
        return ActivitySnapshot(
            id: "focus.current",
            kind: .focus,
            priority: .normal,
            title: "Focus is on",
            detail: "Notifications are being limited",
            actions: [.navigate(.focus)]
        )
    }

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds.rounded(.up)) / 60)
        if totalMinutes < 1 { return "under a minute" }
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private static func clockDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let remainder = value % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private static func batterySymbol(percent: Int) -> String {
        switch percent {
        case 0 ..< 13: "battery.0"
        case 13 ..< 38: "battery.25"
        case 38 ..< 63: "battery.50"
        case 63 ..< 88: "battery.75"
        default: "battery.100"
        }
    }
}
