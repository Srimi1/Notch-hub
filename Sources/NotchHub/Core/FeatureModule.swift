import SwiftUI

enum FeatureModule: String, CaseIterable, Identifiable {
    case dashboard
    case media
    case calendar
    case todo
    case notes
    case pomodoro
    case dayProgress
    case screenTime
    case notifications
    case aiCoding
    case codeHosting
    case translation
    case liveActivities
    case dropActions
    case shelf
    case clipboard
    case focus
    case ramCleaner
    case windowSnap
    case bluetooth
    case systemMonitor
    case shortcuts
    case displays
    case captureVisibility
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .media: "Media"
        case .calendar: "Calendar"
        case .todo: "Todo"
        case .notes: "Notes"
        case .pomodoro: "Pomodoro"
        case .dayProgress: "Day Progress"
        case .screenTime: "Screen Time"
        case .notifications: "Notifications"
        case .aiCoding: "AI Coding"
        case .codeHosting: "Code Hosting"
        case .translation: "Translation"
        case .liveActivities: "Live Activities"
        case .dropActions: "Drop Actions"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .focus: "Focus"
        case .ramCleaner: "Clean RAM"
        case .windowSnap: "Window Snap"
        case .bluetooth: "Bluetooth"
        case .systemMonitor: "System Monitor"
        case .shortcuts: "Shortcuts"
        case .displays: "Displays"
        case .captureVisibility: "Capture"
        case .support: "Support"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .media: "play.circle"
        case .calendar: "calendar"
        case .todo: "checklist"
        case .notes: "note.text"
        case .pomodoro: "timer"
        case .dayProgress: "sun.max"
        case .screenTime: "chart.pie"
        case .notifications: "bell"
        case .aiCoding: "terminal"
        case .codeHosting: "point.3.connected.trianglepath.dotted"
        case .translation: "character.book.closed"
        case .liveActivities: "waveform"
        case .dropActions: "tray.and.arrow.down"
        case .shelf: "shippingbox"
        case .clipboard: "doc.on.clipboard"
        case .focus: "moon.fill"
        case .ramCleaner: "memorychip"
        case .windowSnap: "rectangle.3.group"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .systemMonitor: "cpu"
        case .shortcuts: "keyboard"
        case .displays: "rectangle.on.rectangle"
        case .captureVisibility: "video.slash"
        case .support: "questionmark.circle"
        }
    }

    var summary: String {
        switch self {
        case .dashboard:
            "Four widget slots, profiles, weather, launcher, quotes, toggles, shortcuts, events, and mirror."
        case .media:
            "Now Playing cards, artwork, gradients, transport controls, browser/system audio, and visualizers."
        case .calendar:
            "Upcoming events, reminders, countdowns, meeting awareness, and Focus-aware context."
        case .todo:
            "Add, complete, delete, and restore tasks, with Reminders sync planned."
        case .notes:
            "A quick scratchpad for capture, plus note creation and opening from the notch."
        case .pomodoro:
            "Custom work and break cycles with progress and phase-change notifications."
        case .dayProgress:
            "A timeline for calendar events, reminders, tasks, and an optional bedtime marker."
        case .screenTime:
            "Category charts, ranked apps, app-switch counts, and a daily donut summary."
        case .notifications:
            "Centered alert inbox, unread glance, clearing, and reply actions."
        case .aiCoding:
            "Claude Code and Cursor Agent sessions with status, messages, and Allow/Deny controls."
        case .codeHosting:
            "GitHub PRs, GitLab MRs, and Bitbucket PRs waiting on review or opened by you."
        case .translation:
            "OpenAI or Ollama translation with selectable provider, model, and languages."
        case .liveActivities:
            "Collapsed strip rotation for media, timers, calendar, Bluetooth, app updates, HUDs, and notices."
        case .dropActions:
            "Drop files for Shelf, AirDrop, cloud, zip, unzip, image convert, move, copy, open with, Music, trash, and eject."
        case .shelf:
            "A carousel stash: drop files in, then drag them out when ready."
        case .clipboard:
            "Recent copied text, images, and files (incl. video) with one-click restore to the clipboard."
        case .focus:
            "Toggle macOS Do Not Disturb and see whether a Focus is currently active."
        case .ramCleaner:
            "Free up inactive memory in one tap and see how much was reclaimed."
        case .windowSnap:
            "Top-edge snap tiles for halves, thirds, quarters, maximize, and custom layouts."
        case .bluetooth:
            "Connected devices with battery levels and low-battery alerts."
        case .systemMonitor:
            "Live CPU, RAM, storage, and network-style health indicators."
        case .shortcuts:
            "Keyboard recording for snooze, module navigation, hover-only behavior, and duration."
        case .displays:
            "Physical notch optional, external display support, and per-screen placement controls."
        case .captureVisibility:
            "Control whether the notch is visible in screenshots, recordings, and screen sharing."
        case .support:
            "Support links, licensing/trial placeholders, and community entry points."
        }
    }

    var items: [String] {
        switch self {
        case .dashboard:
            ["Widget slots", "Focus profiles", "Weather", "App launcher", "Quotes", "Mirror"]
        case .media:
            ["Artwork", "Prev/play/next", "Spotify", "Apple Music", "Plex", "VLC", "Spectrum"]
        case .calendar:
            ["Events", "Reminders", "Countdowns", "Meeting focus"]
        case .todo:
            ["Add", "Complete", "Trash", "Restore", "Reminders sync"]
        case .notes:
            ["Scratchpad", "Create note", "Open note"]
        case .pomodoro:
            ["Work cycle", "Break cycle", "Progress", "Notifications"]
        case .dayProgress:
            ["Calendar", "Reminders", "Tasks", "Bedtime marker", "Today summary"]
        case .screenTime:
            ["Categories", "Ranked apps", "Switch count", "Donut widget", "Exclusions"]
        case .notifications:
            ["Unread glance", "Clear", "Reply", "App icons"]
        case .aiCoding:
            ["Claude Code", "Cursor Agent", "Live status", "Recent messages", "Allow/Deny"]
        case .codeHosting:
            ["GitHub", "GitLab", "Bitbucket", "Review queue", "Opened by me"]
        case .translation:
            ["OpenAI", "Ollama", "Models", "Languages"]
        case .liveActivities:
            ["Media", "Timers", "Calendar", "Bluetooth", "HUD", "Notices"]
        case .dropActions:
            ["Shelf", "AirDrop", "Cloud", "Zip", "Unzip", "Convert", "Move", "Copy", "Open With", "Music", "Trash", "Eject"]
        case .shelf:
            ["Drop in", "Drag out", "Carousel", "Drop Actions tile"]
        case .clipboard:
            ["Text", "Images", "Files & video", "Copy back", "Private local only"]
        case .focus:
            ["Do Not Disturb", "Focus status", "One-tap toggle"]
        case .ramCleaner:
            ["Free RAM", "Live usage", "No password", "One tap"]
        case .windowSnap:
            ["Halves", "Thirds", "Quarters", "Maximize", "Tile reorder"]
        case .bluetooth:
            ["AirPods", "Mice", "Keyboards", "Trackpads", "Controllers", "Battery alerts"]
        case .systemMonitor:
            ["CPU", "RAM", "Storage", "Indicators"]
        case .shortcuts:
            ["Snooze", "Module navigation", "Hover-only", "Duration"]
        case .displays:
            ["Notched Macs", "Notchless Macs", "External displays", "Multiple screens"]
        case .captureVisibility:
            ["Screenshots", "Recordings", "Screen sharing"]
        case .support:
            ["Trial", "License", "Email", "Discord"]
        }
    }
}
