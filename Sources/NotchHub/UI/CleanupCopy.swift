import Foundation

/// Every word the cache segment can say, as a value.
///
/// Pure, and separate from the view, for the reason the rest of this project
/// keeps its rules out of `body`: the difference between "nothing found yet"
/// and "nothing to find" is a sentence a test can check, not something to
/// verify by hovering a running app.
struct CleanupCopy: Equatable {

    /// What the button does next. `nil` when there is nothing to press.
    enum Action: Equatable {
        case scan
        case clean
        case rescan
        case retry
        case openSettings(SystemSettingsPane)

        var title: String {
            switch self {
            case .scan: "Scan"
            case .clean: "Clean"
            case .rescan: "Rescan"
            case .retry: "Retry"
            case .openSettings: "Fix…"
            }
        }
    }

    let symbol: String
    let title: String
    let caption: String
    let isError: Bool
    /// The action the button performs, and whether it can be pressed now.
    let action: Action
    let isActionEnabled: Bool

    var accessibilityLabel: String {
        switch action {
        case .scan, .rescan: "Scan caches"
        case .clean: "Move safe caches to the Trash"
        case .retry: "Try the cache scan again"
        case .openSettings: "Open the settings pane that fixes this"
        }
    }

    static func make(state: CacheCleanupService.State, now: Date) -> CleanupCopy {
        switch state {
        case .unscanned:
            return CleanupCopy(
                symbol: "trash", title: "Caches", caption: "Not scanned yet",
                isError: false, action: .scan, isActionEnabled: true
            )
        case let .scanning(bytes):
            return CleanupCopy(
                symbol: "arrow.triangle.2.circlepath",
                title: "Scanning caches…",
                caption: bytes > 0 ? "\(format(bytes)) found so far" : "Sizing ~/Library/Caches",
                isError: false, action: .clean, isActionEnabled: false
            )
        case let .ready(summary):
            return CleanupCopy(
                symbol: "trash",
                title: "\(format(summary.safeBytes)) safe to clean",
                caption: readyCaption(summary, now: now),
                isError: false, action: .clean, isActionEnabled: true
            )
        case let .tidy(summary):
            return CleanupCopy(
                symbol: "checkmark.circle",
                title: "Caches are tidy",
                caption: tidyCaption(summary, now: now),
                isError: false, action: .rescan, isActionEnabled: true
            )
        case let .cleaning(count):
            return CleanupCopy(
                symbol: "trash", title: "Cleaning…",
                caption: "Moving \(count) \(count == 1 ? "folder" : "folders") to the Trash",
                isError: false, action: .clean, isActionEnabled: false
            )
        case let .cleaned(result):
            let problems = result.problemCount
            return CleanupCopy(
                symbol: "checkmark.circle.fill",
                title: "\(format(result.movedBytes)) moved to the Trash",
                caption: problems > 0
                    ? "\(problems) could not be moved"
                    : "Empty the Trash to free the space",
                isError: problems > 0, action: .clean, isActionEnabled: false
            )
        case let .failed(error):
            return CleanupCopy(
                symbol: "exclamationmark.triangle.fill",
                title: isCleanFailure(error) ? "Could not clean caches" : "Could not scan caches",
                caption: error.message,
                isError: true,
                action: error.settingsPane.map { Action.openSettings($0) } ?? .retry,
                isActionEnabled: true
            )
        }
    }

    /// The house byte style: `Int.formatted(.byteCount(style: .file))`.
    static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private static func readyCaption(_ summary: CacheScanSummary, now: Date) -> String {
        let scanned = "Scanned \(RelativeTime.ago(summary.date, now: now))"
        guard summary.checkFirstCount > 0 else { return scanned }
        return "\(scanned) · \(summary.checkFirstCount) to check first"
    }

    private static func tidyCaption(_ summary: CacheScanSummary, now: Date) -> String {
        let when = RelativeTime.ago(summary.date, now: now)
        guard summary.checkFirstCount > 0 else { return "Under 64 MB to clean · \(when)" }
        return "\(summary.checkFirstCount) to check first · \(when)"
    }

    private static func isCleanFailure(_ error: CleanupError) -> Bool {
        if case .nothingMoved = error { return true }
        return false
    }
}
