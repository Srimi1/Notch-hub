import AppKit

struct AppInstanceCandidate: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleURL: URL
    let bundleVersion: String
    let modificationDate: Date

    var isCanonicalBundle: Bool {
        bundleURL.lastPathComponent == "NotchHub.app"
    }
}

enum AppInstanceSelector {
    static func primary(in candidates: [AppInstanceCandidate]) -> AppInstanceCandidate? {
        candidates.max { lhs, rhs in
            if lhs.isCanonicalBundle != rhs.isCanonicalBundle {
                return !lhs.isCanonicalBundle
            }

            let versionOrder = lhs.bundleVersion.compare(rhs.bundleVersion, options: .numeric)
            if versionOrder != .orderedSame {
                return versionOrder == .orderedAscending
            }

            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate < rhs.modificationDate
            }

            // Prefer the process that started first when every bundle property matches.
            return lhs.processIdentifier > rhs.processIdentifier
        }
    }
}

/// Ensures copied builds with the same bundle identifier cannot create several
/// menu-bar items and notch overlays at once.
@MainActor
final class AppInstanceCoordinator {
    private let workspace: NSWorkspace
    private let currentApplication: NSRunningApplication

    init(
        workspace: NSWorkspace = .shared,
        currentApplication: NSRunningApplication = .current
    ) {
        self.workspace = workspace
        self.currentApplication = currentApplication
    }

    func shouldContinueLaunching() -> Bool {
        guard let bundleIdentifier = currentApplication.bundleIdentifier else {
            NSLog("NotchHub instances: current bundle has no identifier; continuing safely")
            return true
        }

        let runningApplications = workspace.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
        let candidates = runningApplications.compactMap(makeCandidate)

        guard let primary = AppInstanceSelector.primary(in: candidates) else {
            NSLog("NotchHub instances: unable to inspect running bundles; continuing safely")
            return true
        }

        guard primary.processIdentifier == currentApplication.processIdentifier else {
            NSLog(
                "NotchHub instances: using existing canonical app at %@",
                primary.bundleURL.path
            )
            return false
        }

        retireDuplicates(in: runningApplications)
        return true
    }

    private func makeCandidate(for application: NSRunningApplication) -> AppInstanceCandidate? {
        guard let bundleURL = application.bundleURL else {
            NSLog(
                "NotchHub instances: process %d has no bundle URL",
                application.processIdentifier
            )
            return nil
        }

        let bundleVersion = Bundle(url: bundleURL)?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let modificationDate: Date
        do {
            modificationDate = try bundleURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
        } catch {
            NSLog(
                "NotchHub instances: failed to read modification date for %@: %@",
                bundleURL.path,
                error.localizedDescription
            )
            modificationDate = .distantPast
        }

        return AppInstanceCandidate(
            processIdentifier: application.processIdentifier,
            bundleURL: bundleURL,
            bundleVersion: bundleVersion,
            modificationDate: modificationDate
        )
    }

    private func retireDuplicates(in applications: [NSRunningApplication]) {
        let duplicates = applications.filter {
            $0.processIdentifier != currentApplication.processIdentifier
        }
        for application in duplicates {
            if application.terminate() {
                NSLog(
                    "NotchHub instances: retired duplicate process %d",
                    application.processIdentifier
                )
            } else if application.forceTerminate() {
                NSLog(
                    "NotchHub instances: force-retired unresponsive duplicate process %d",
                    application.processIdentifier
                )
            } else {
                NSLog(
                    "NotchHub instances: failed to retire duplicate process %d",
                    application.processIdentifier
                )
            }
        }
    }
}
