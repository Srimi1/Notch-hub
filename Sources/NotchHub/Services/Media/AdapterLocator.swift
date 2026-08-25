import Foundation

/// Finds the two files the MediaRemote adapter needs: the Perl script and the
/// helper framework it loads.
///
/// Both are copied into the app bundle by `scripts/build-app.sh`. Neither is
/// linked or imported — the framework's path is nothing but an argument handed
/// to `/usr/bin/perl`. When either is missing (a plain `swift run`, a bundle
/// assembled by other means), the answer is `nil` and the adapter is simply not
/// used. That is a supported state, not an error: the AppleScript source still
/// covers Music and Spotify.
enum AdapterLocator {

    /// The Apple-signed interpreter. The whole approach rests on this specific
    /// binary: processes whose bundle id starts with `com.apple.` are the only
    /// ones macOS still lets near MediaRemote, and `/usr/bin/perl` is one.
    static let perlPath = "/usr/bin/perl"

    static let scriptName = "mediaremote-adapter.pl"
    static let frameworkName = "MediaRemoteAdapter.framework"

    /// Overrides the bundle lookup so the adapter can be exercised outside a
    /// built `.app` — `swift run`, tests, a one-off build in a scratch dir.
    static let directoryEnvironmentKey = "NOTCHHUB_ADAPTER_DIR"

    struct Paths: Equatable {
        var perl: String
        var script: String
        var framework: String
    }

    static func locate(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Paths? {
        guard fileExists(perlPath) else { return nil }

        for directory in candidateDirectories(bundle: bundle, environment: environment) {
            let script = directory.script
            let framework = directory.framework
            if fileExists(script), fileExists(framework) {
                return Paths(perl: perlPath, script: script, framework: framework)
            }
        }
        return nil
    }

    private struct Candidate {
        var script: String
        var framework: String
    }

    /// The override directory holds both files side by side; the app bundle
    /// keeps the script in `Resources` and the framework in `Frameworks`.
    private static func candidateDirectories(
        bundle: Bundle,
        environment: [String: String]
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        if let override = environment[directoryEnvironmentKey], !override.isEmpty {
            let base = URL(fileURLWithPath: override, isDirectory: true)
            candidates.append(Candidate(
                script: base.appendingPathComponent(scriptName).path,
                framework: base.appendingPathComponent(frameworkName).path
            ))
        }

        if let resources = bundle.resourceURL {
            let frameworks = bundle.privateFrameworksURL
                ?? resources.deletingLastPathComponent().appendingPathComponent("Frameworks")
            candidates.append(Candidate(
                script: resources.appendingPathComponent(scriptName).path,
                framework: frameworks.appendingPathComponent(frameworkName).path
            ))
        }

        return candidates
    }
}
