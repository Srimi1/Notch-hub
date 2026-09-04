import Foundation

/// What one scan is asked to cover. Captured on the main actor when the scan
/// starts, so a switch flipped mid-scan changes the next scan, not this one.
struct CacheScanPlan: Sendable, Equatable {
    let home: URL
    let includeDeveloperCaches: Bool
    let includeContainers: Bool
}

/// The scan and the clean, as pure functions over `CacheCleanupIO`.
///
/// Nothing here is isolated to an actor: `CacheCleanupService` runs these in a
/// detached task and receives a value back. That is also what makes them
/// testable with a fake in place of the disk.
enum CacheCleanupEngine {

    // MARK: - Scan

    static func scan(
        _ plan: CacheScanPlan,
        io: CacheCleanupIO,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (Int64) -> Void,
        now: Date
    ) -> CacheScanOutcome {
        var outcome = CacheScanOutcome(finishedAt: now)
        var seen = Set<String>()
        var candidates: [CacheCandidate] = []

        func offer(_ candidate: CacheCandidate) {
            guard seen.insert(candidate.url.standardizedFileURL.path).inserted else { return }
            candidates.append(candidate)
        }

        switch appCacheCandidates(plan, io: io) {
        case let .failure(error):
            outcome.failure = error
            return outcome
        case let .success(found):
            found.forEach(offer)
        }
        logCandidates(plan, io: io).forEach(offer)
        if plan.includeDeveloperCaches {
            developerCandidates(home: plan.home, io: io).forEach(offer)
        }
        if plan.includeContainers {
            containerCandidates(plan, io: io).forEach(offer)
        }

        return size(candidates, into: outcome, io: io, isCancelled: isCancelled, progress: progress)
    }

    /// Measure each candidate, safe ones first so a scan cut short has already
    /// counted what the button acts on.
    private static func size(
        _ candidates: [CacheCandidate],
        into outcome: CacheScanOutcome,
        io: CacheCleanupIO,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (Int64) -> Void
    ) -> CacheScanOutcome {
        var outcome = outcome
        let ordered = candidates.filter { $0.level == .safe } + candidates.filter { $0.level == .medium }
        var sized: [CacheCandidate] = []
        var safeBytes: Int64 = 0
        for var candidate in ordered {
            if isCancelled() {
                outcome.cancelled = true
                return outcome
            }
            candidate.bytes = io.allocatedSize(candidate.url, isCancelled)
            sized.append(candidate)
            if candidate.level == .safe {
                safeBytes += candidate.bytes
                progress(safeBytes)
            }
        }
        outcome.candidates = sized
        return outcome
    }

    /// `~/Library/Caches` is the one root whose failure is the scan's failure:
    /// without it there is nothing worth reporting.
    private static func appCacheCandidates(
        _ plan: CacheScanPlan, io: CacheCleanupIO
    ) -> Result<[CacheCandidate], CleanupError> {
        let root = plan.home.appendingPathComponent("Library/Caches", isDirectory: true)
        return list(root, io: io, home: plan.home).map { children in
            children.filter(\.hasDirectoryPath).compactMap { child in
                guard let found = CacheSafetyPolicy.classify(
                    cachesFolderNamed: child.lastPathComponent,
                    includeDeveloperCaches: plan.includeDeveloperCaches,
                    fullDiskAccess: plan.includeContainers
                ) else { return nil }
                return CacheCandidate(
                    url: child,
                    title: found.title,
                    level: found.level,
                    kind: found.scope == .devTools ? .developerTool : .appCache,
                    deleteContentsOnly: false
                )
            }
        }
    }

    private static func logCandidates(_ plan: CacheScanPlan, io: CacheCleanupIO) -> [CacheCandidate] {
        let root = plan.home.appendingPathComponent("Library/Logs", isDirectory: true)
        guard case let .success(children) = list(root, io: io, home: plan.home) else { return [] }
        return children.compactMap { child in
            guard let found = CacheSafetyPolicy.classify(logEntryNamed: child.lastPathComponent) else { return nil }
            return CacheCandidate(
                url: child, title: found.title, level: found.level, kind: .log, deleteContentsOnly: false
            )
        }
    }

    /// A listing, with a missing folder read as empty: a Mac with no
    /// `~/Library/Logs` has nothing to clean there, which is not an error.
    private static func list(_ root: URL, io: CacheCleanupIO, home: URL) -> Result<[URL], CleanupError> {
        do {
            return .success(try io.enumerateTopLevel(root))
        } catch {
            let folder = abbreviatingHome(root, home: home)
            if isMissing(error) { return .success([]) }
            if isPermissionFailure(error) {
                NSLog("NotchHub cleanup: macOS refused %@", folder)
                return .failure(.permissionRefused(folder: folder))
            }
            NSLog("NotchHub cleanup: could not read %@: %@", folder, error.localizedDescription)
            return .failure(.folderUnreadable(folder: folder, reason: error.localizedDescription))
        }
    }

    private static func developerCandidates(home: URL, io: CacheCleanupIO) -> [CacheCandidate] {
        let cachesRoot = home.appendingPathComponent("Library/Caches", isDirectory: true).standardizedFileURL.path
        var found: [CacheCandidate] = []
        for tool in CacheCatalog.devToolCaches {
            guard let entry = CacheCatalog.entry(forKey: tool.catalogKey) else {
                NSLog("NotchHub cleanup: developer cache %@ has no catalog entry", tool.catalogKey)
                continue
            }
            for relative in tool.relativePaths {
                let url = home.appendingPathComponent(relative, isDirectory: true)
                // Anything under ~/Library/Caches was already offered by name.
                guard !url.standardizedFileURL.path.hasPrefix(cachesRoot + "/") else { continue }
                guard io.exists(url) else { continue }
                guard CacheSafetyPolicy.locationDecision(for: url, home: home) == .allowed else { continue }
                found.append(CacheCandidate(
                    url: url, title: entry.displayName, level: entry.level,
                    kind: .developerTool, deleteContentsOnly: false
                ))
            }
        }
        return found
    }

    private static func containerCandidates(_ plan: CacheScanPlan, io: CacheCleanupIO) -> [CacheCandidate] {
        let root = plan.home.appendingPathComponent("Library/Containers", isDirectory: true)
        guard case let .success(children) = list(root, io: io, home: plan.home) else { return [] }
        var found: [CacheCandidate] = []
        for child in children where child.hasDirectoryPath {
            let bundleID = child.lastPathComponent
            guard let classification = CacheSafetyPolicy.classify(
                containerBundleID: bundleID, includeDeveloperCaches: plan.includeDeveloperCaches
            ) else { continue }
            let caches = child.appendingPathComponent("Data/Library/Caches", isDirectory: true)
            guard io.exists(caches) else { continue }
            found.append(CacheCandidate(
                url: caches, title: classification.title, level: classification.level, kind: .container,
                deleteContentsOnly: true
            ))
        }
        return found
    }

    // MARK: - Clean

    static func clean(
        _ targets: [CacheCandidate],
        home: URL,
        io: CacheCleanupIO,
        isCancelled: @Sendable () -> Bool,
        now: Date
    ) -> CleanOutcome {
        var summary = CleanSummary(movedBytes: 0, movedCount: 0, failedCount: 0, skippedCount: 0, date: now)
        var outcome = CleanOutcome(summary: summary, attempted: targets.count)

        for target in targets {
            if isCancelled() {
                outcome.cancelled = true
                break
            }
            if target.deleteContentsOnly {
                cleanContents(of: target, home: home, io: io, into: &summary)
            } else {
                move(Move(url: target.url, title: target.title, bytes: target.bytes, level: target.level),
                     home: home, io: io, into: &summary)
            }
        }
        outcome.summary = summary
        return outcome
    }

    /// A container's cache folder stays; its children go. The candidate's
    /// bytes are credited if anything inside moved — the same approximation
    /// Purge makes, since the children were never sized on their own.
    private static func cleanContents(
        of target: CacheCandidate, home: URL, io: CacheCleanupIO, into summary: inout CleanSummary
    ) {
        let children: [URL]
        do {
            children = try io.enumerateTopLevel(target.url)
        } catch {
            summary.failedCount += 1
            record("\(target.title): \(error.localizedDescription)", into: &summary)
            return
        }
        var inner = CleanSummary(movedBytes: 0, movedCount: 0, failedCount: 0, skippedCount: 0, date: summary.date)
        for child in children {
            move(Move(url: child, title: target.title, bytes: 0, level: target.level),
                 home: home, io: io, into: &inner)
        }
        if inner.movedCount > 0 {
            summary.movedCount += 1
            summary.movedBytes += target.bytes
        }
        summary.failedCount += inner.failedCount
        summary.skippedCount += inner.skippedCount
        if let failure = inner.firstFailure { record(failure, into: &summary) }
    }

    /// One thing on its way to the Trash: a candidate, or one child of a
    /// contents-only candidate.
    private struct Move {
        let url: URL
        let title: String
        let bytes: Int64
        let level: CacheSafetyLevel
    }

    private static func move(_ item: Move, home: URL, io: CacheCleanupIO, into summary: inout CleanSummary) {
        switch CacheSafetyPolicy.trashDecision(for: item.url, level: item.level, home: home) {
        case let .refused(reason):
            summary.skippedCount += 1
            NSLog("NotchHub cleanup: refused %@ (%@)", item.url.path, reason.description)
        case .allowed:
            do {
                try io.trash(item.url)
                summary.movedCount += 1
                summary.movedBytes += item.bytes
            } catch {
                summary.failedCount += 1
                NSLog("NotchHub cleanup: could not move %@: %@", item.url.path, error.localizedDescription)
                record("\(item.title): \(error.localizedDescription)", into: &summary)
            }
        }
    }

    private static func record(_ failure: String, into summary: inout CleanSummary) {
        if summary.firstFailure == nil { summary.firstFailure = failure }
    }

    // MARK: - Error classification

    static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError { return true }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    static func isPermissionFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return isPermissionFailure(underlying)
        }
        return false
    }
}
