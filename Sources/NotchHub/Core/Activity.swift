import Foundation

enum ActivityKind: String, CaseIterable, Codable, Sendable {
    case calendar
    case timer
    case reminder
    case battery
    case media
    case focus

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .timer: "Timers"
        case .reminder: "Reminders"
        case .battery: "Battery"
        case .media: "Media"
        case .focus: "Focus"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .timer: "timer"
        case .reminder: "checkmark.circle"
        case .battery: "battery.25"
        case .media: "waveform"
        case .focus: "moon.fill"
        }
    }
}

enum ActivityPriority: Int, Codable, Sendable {
    case ambient = 100
    case normal = 200
    case foreground = 250
    case timeSensitive = 300
    case urgent = 400
    case critical = 500
}

enum ActivityAction: Equatable, Sendable {
    case joinMeeting(URL)
    case openLocation(String)
    case openCalendar
    case completeReminder(String)
    case requestRemindersAccess
    case pauseTimer(UUID)
    case resumeTimer(UUID)
    case cancelTimer(UUID)
    case dismissTimer(UUID)
    case toggleMedia
    case navigate(FeatureModule)

    var title: String {
        switch self {
        case .joinMeeting: "Join"
        case .openLocation: "Directions"
        case .openCalendar: "Calendar"
        case .completeReminder: "Complete"
        case .requestRemindersAccess: "Enable"
        case .pauseTimer: "Pause"
        case .resumeTimer: "Resume"
        case .cancelTimer: "Cancel"
        case .dismissTimer: "Dismiss"
        case .toggleMedia: "Play/Pause"
        case let .navigate(module): module.title
        }
    }

    var symbol: String {
        switch self {
        case .joinMeeting: "video.fill"
        case .openLocation: "map.fill"
        case .openCalendar: "calendar"
        case .completeReminder: "checkmark"
        case .requestRemindersAccess: "hand.raised.fill"
        case .pauseTimer: "pause.fill"
        case .resumeTimer: "play.fill"
        case .cancelTimer: "xmark"
        case .dismissTimer: "checkmark"
        case .toggleMedia: "playpause.fill"
        case let .navigate(module): module.symbol
        }
    }
}

struct ActivitySnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ActivityKind
    let priority: ActivityPriority
    let title: String
    let detail: String
    let symbol: String
    let relevanceDate: Date?
    let actions: [ActivityAction]

    init(
        id: String,
        kind: ActivityKind,
        priority: ActivityPriority,
        title: String,
        detail: String,
        symbol: String? = nil,
        relevanceDate: Date? = nil,
        actions: [ActivityAction] = []
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.title = title
        self.detail = detail
        self.symbol = symbol ?? kind.symbol
        self.relevanceDate = relevanceDate
        self.actions = Array(actions.prefix(2))
    }

    var compactLabel: String {
        switch kind {
        case .calendar:
            return detail
        case .timer:
            return detail
                .replacingOccurrences(of: "Paused · ", with: "")
                .replacingOccurrences(of: " remaining", with: "")
        case .reminder, .media:
            return title
        case .battery:
            let percent = title.replacingOccurrences(of: "Battery ", with: "")
            let estimate = detail
                .replacingOccurrences(of: " remaining", with: "")
                .replacingOccurrences(of: " until full", with: "")
            return estimate == "On battery power" || estimate == "Fully charged"
                ? percent
                : "\(percent) · \(estimate)"
        case .focus:
            return "Focus"
        }
    }
}

// `SafeExternalURL` and `DisplaySanitizer` — the guards for data that arrives
// from other applications — live in `UntrustedInput.swift`.
