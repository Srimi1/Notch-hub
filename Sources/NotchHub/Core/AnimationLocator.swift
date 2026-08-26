import Foundation

/// Finds the Lottie animations the app draws with.
///
/// They are plain JSON copied into the bundle by `scripts/build-app.sh`, found
/// by path rather than by `Bundle.module` — this package declares no SwiftPM
/// resources, so the adapter's arrangement is the one to follow (see
/// `AdapterLocator`). A missing file answers `nil` and the view that wanted it
/// simply draws what it drew before. That is a supported state, not an error:
/// the astronaut is decoration, and a bundle assembled by other means should
/// still run.
enum AnimationLocator {

    /// The astronaut who listens to music while the notch is open.
    static let astronautName = "astronaut-and-music"

    /// The bundle subdirectory the animations live in.
    static let directoryName = "Animations"

    /// Overrides the bundle lookup so the animations resolve outside a built
    /// `.app` — `swift run`, tests, a one-off build in a scratch directory.
    static let directoryEnvironmentKey = "NOTCHHUB_ANIMATIONS_DIR"

    static func locate(
        _ name: String,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        for directory in candidateDirectories(bundle: bundle, environment: environment) {
            let candidate = directory.appendingPathComponent(name + ".json")
            if fileExists(candidate.path) { return candidate }
        }
        return nil
    }

    /// The override directory holds the JSON files directly; the app bundle
    /// keeps them in an `Animations` folder inside `Resources`. The bare
    /// resource directory is checked too, so a flatter bundle still works.
    private static func candidateDirectories(
        bundle: Bundle,
        environment: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []

        if let override = environment[directoryEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent(directoryName, isDirectory: true))
            candidates.append(resources)
        }

        return candidates
    }
}
