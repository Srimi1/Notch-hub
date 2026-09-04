import Foundation

/// Compact time strings for chips and tiles. Pure formatting, no state — it
/// lives here rather than in `Core/` because every caller is a view.
enum RelativeTime {
    static func timer(_ interval: TimeInterval) -> String {
        let value = max(0, Int(interval.rounded(.up)))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let seconds = value % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Wall-clock time, in whatever form the user's region uses.
    ///
    /// This runs inside views that redraw every second, and the old
    /// `DateFormatter` here was rebuilt on each of those calls — one of the most
    /// expensive objects in Foundation, allocated for a five-character string.
    /// `FormatStyle` is a value type with its own caching, and it follows the
    /// system 24-hour setting instead of forcing `h:mm a` on everyone.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "now", "in 12m", "in 3h" — compact countdown for chips.
    static func short(to date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "in \(max(minutes, 1))m" }
        let hours = minutes / 60
        return "in \(hours)h"
    }

    /// "now", "2m ago", "3h ago" — compact elapsed time for past events.
    static func ago(_ date: Date) -> String {
        ago(date, now: .now)
    }

    /// The same, against an explicit clock, so copy built from it can be
    /// tested without waiting.
    static func ago(_ date: Date, now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
