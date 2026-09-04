import Foundation
import Lottie
import OSLog

enum AstronautMotion: Equatable, Sendable {
    case looping
    case still

    init(isPlaying: Bool, reduceMotion: Bool) {
        self = isPlaying && !reduceMotion ? .looping : .still
    }

    var lottieMode: LottiePlaybackMode {
        switch self {
        case .looping:
            .playing(.fromProgress(0, toProgress: 1, loopMode: .loop))
        case .still:
            .paused
        }
    }
}

/// Decodes the single trusted, bundled media illustration once per launch.
@MainActor
enum AstronautAnimation {
    enum Ink: Hashable, Sendable {
        case asDrawn
        case white
    }

    private static var cached: [Ink: LottieAnimation] = [:]
    private static var attempted: Set<Ink> = []
    private static var pending: [Ink: Task<LottieAnimation?, Never>] = [:]
    private nonisolated static let logger = Logger(
        subsystem: "com.srimi.NotchHub",
        category: "MediaAnimation"
    )
    private nonisolated static let maximumAssetBytes = 2 * 1024 * 1024

    static func load(_ ink: Ink = .asDrawn) async -> LottieAnimation? {
        if let cached = cached[ink] {
            return cached
        }
        if let pending = pending[ink] {
            return await pending.value
        }
        guard attempted.insert(ink).inserted else { return nil }

        let url = animationURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            report(AstronautAnimationLoadError.missingAsset)
            return nil
        }

        let decodeTask = Task.detached(priority: .utility) {
            decode(url, ink: ink)
        }
        pending[ink] = decodeTask
        let animation = await decodeTask.value
        pending[ink] = nil
        if let animation {
            cached[ink] = animation
        }
        return animation
    }

    nonisolated static func duration(of url: URL) -> TimeInterval? {
        decode(url)?.duration
    }

    nonisolated static func inverted(_ json: Data) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: json)
        let swapped = swapTones(in: root)
        return try JSONSerialization.data(withJSONObject: swapped)
    }

    private nonisolated static var animationURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Animations", isDirectory: true)
            .appendingPathComponent("astronaut-and-music.json", isDirectory: false)
    }

    private nonisolated static func decode(
        _ url: URL,
        ink: Ink = .asDrawn
    ) -> LottieAnimation? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw AstronautAnimationLoadError.notRegularFile
            }
            if let size = values.fileSize, size > maximumAssetBytes {
                throw AstronautAnimationLoadError.assetTooLarge(size)
            }
            var data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumAssetBytes else {
                throw AstronautAnimationLoadError.assetTooLarge(data.count)
            }
            if ink == .white {
                data = try inverted(data)
            }
            return try JSONDecoder().decode(LottieAnimation.self, from: data)
        } catch {
            report(error)
            return nil
        }
    }

    private nonisolated static func swapTones(in node: Any) -> Any {
        if let dictionary = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = key == "c" ? swapColour(in: value) : swapTones(in: value)
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map { swapTones(in: $0) }
        }
        return node
    }

    private nonisolated static func swapColour(in node: Any) -> Any {
        if let dictionary = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = ["k", "s", "e"].contains(key)
                    ? swapColour(in: swapChannels(in: value))
                    : swapColour(in: value)
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map { swapColour(in: $0) }
        }
        return node
    }

    private nonisolated static func swapChannels(in value: Any) -> Any {
        guard let channels = value as? [Any], channels.count >= 3 else { return value }
        let numbers = channels.prefix(3).compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 3 else { return value }

        let isNearBlack = numbers.allSatisfy { $0 < 0.2 }
        let isWhite = numbers.allSatisfy { $0 > 0.8 }
        guard isNearBlack || isWhite else { return value }

        let replacement: [Double] = isNearBlack ? [1, 1, 1] : [0, 0, 0]
        var result = channels
        for index in 0 ..< 3 {
            result[index] = replacement[index]
        }
        return result
    }

    private nonisolated static func report(_ error: Error) {
        logger.error("Astronaut animation unavailable: \(error.localizedDescription, privacy: .public)")
    }
}

private enum AstronautAnimationLoadError: LocalizedError, Sendable {
    case missingAsset
    case notRegularFile
    case assetTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingAsset:
            "The bundled astronaut-and-music.json asset is missing."
        case .notRegularFile:
            "The bundled astronaut animation is not a regular file."
        case let .assetTooLarge(size):
            "The bundled astronaut animation is unexpectedly large (\(size) bytes)."
        }
    }
}
