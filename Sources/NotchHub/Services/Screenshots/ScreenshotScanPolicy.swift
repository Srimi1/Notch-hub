import Foundation

/// Which files a directory scan should look at, and how often an unfinished one
/// is looked at again.
///
/// Pure, so the rules can be tested without a folder, a timer, or a screenshot.
enum ScreenshotScanPolicy {

    struct Entry: Sendable, Equatable {
        var url: URL
        var modified: Date
        var size: Int
    }

    /// How many new files one scan will consider.
    ///
    /// Unpacking an archive onto the Desktop drops hundreds of files at once.
    /// None of them will be screenshots, but each one costs an xattr read, and
    /// the watch queue should not disappear into that. Screenshots arrive one
    /// at a time; five per scan is generous for the real case.
    static let maximumCandidatesPerScan = 5

    /// How many times a file that turned up but was not yet finished — or not
    /// yet tagged — is looked at again before it is written off.
    ///
    /// The ladder covers about five and a half seconds, which is what a large
    /// multi-display PNG needs to finish being written. The floating-preview
    /// delay does not eat into it: that happens before the file exists at all.
    static let retryLadder: [TimeInterval] = [0.15, 0.3, 0.6, 1.0, 1.5, 2.0]

    static func retryDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < retryLadder.count else { return nil }
        return retryLadder[attempt]
    }

    /// New files worth opening: modified since the last scan, plausibly an
    /// image by name, newest first, and capped.
    ///
    /// Newest-first matters when the cap bites — the screenshot someone just
    /// took is the one they are waiting to paste.
    static func candidates(
        in entries: [Entry],
        newerThan cutoff: Date,
        excluding handled: Set<String> = [],
        limit: Int = maximumCandidatesPerScan,
        isImageExtension: (String) -> Bool = ScreenshotClassifier.isImageExtension
    ) -> [Entry] {
        entries
            .filter { $0.modified > cutoff }
            .filter { !handled.contains($0.url.standardizedFileURL.path) }
            .filter { isImageExtension($0.url.pathExtension) }
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { $0 }
    }

    /// The cutoff for the *next* scan.
    ///
    /// Deliberately the moment this scan began, never the newest file's
    /// timestamp. A file carrying a modification date in the future — a restore
    /// from backup, a badly-set clock, an SMB share — would otherwise push the
    /// cutoff past every real screenshot and silently switch the feature off
    /// for the rest of the session.
    static func nextCutoff(after current: Date, scanStartedAt start: Date) -> Date {
        max(current, start)
    }

    /// How many recently-handled paths are remembered, so two directory events
    /// for the same screenshot cannot copy it twice.
    static let handledMemory = 32

    static func remembering(_ path: String, in handled: [String]) -> [String] {
        guard !handled.contains(path) else { return handled }
        return Array((handled + [path]).suffix(handledMemory))
    }
}
