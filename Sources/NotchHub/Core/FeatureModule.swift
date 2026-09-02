import SwiftUI

enum FeatureModule: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case media
    case calendar
    case todo
    case pomodoro
    case clipboard
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .media: "Media"
        case .calendar: "Calendar"
        case .todo: "Todo"
        case .pomodoro: "Pomodoro"
        case .clipboard: "Clipboard"
        case .focus: "Focus"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .media: "play.circle"
        case .calendar: "calendar"
        case .todo: "checklist"
        case .pomodoro: "timer"
        case .clipboard: "doc.on.clipboard"
        case .focus: "moon.fill"
        }
    }

    var summary: String {
        switch self {
        case .dashboard:
            "Time, battery, CPU, and memory at a glance."
        case .media:
            "Music and Spotify playback controls."
        case .calendar:
            "Upcoming events, countdowns, and join actions."
        case .todo:
            "Due Apple Reminders with quick completion."
        case .pomodoro:
            "Persistent timers with quick focus presets."
        case .clipboard:
            "Recent clipboard items with one-click restore."
        case .focus:
            "Do Not Disturb, and the cache your Mac can rebuild."
        }
    }
}
