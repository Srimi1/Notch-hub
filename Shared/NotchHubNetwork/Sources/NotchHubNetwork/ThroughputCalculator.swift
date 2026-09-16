// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation

public struct NetworkThroughputCalculator: Sendable {
    public static let sanityCeilingMbps = 50_000.0
    public static let minimumIntervalSeconds = 0.2

    public enum Outcome: Sendable, Equatable {
        case rate(downloadMbps: Double, uploadMbps: Double)
        case rebaseline(reason: RebaselineReason)
        case tooSoon
    }

    public enum RebaselineReason: String, Sendable, Equatable {
        case counterWentBackwards
        case staleGap
        case implausibleRate
    }

    public init() {}

    public func evaluate(
        previous: NetworkInterfaceCounters,
        current: NetworkInterfaceCounters,
        elapsedSeconds: Double,
        maximumGapSeconds: Double = 3
    ) -> Outcome {
        guard elapsedSeconds.isFinite, elapsedSeconds >= Self.minimumIntervalSeconds else {
            return .tooSoon
        }
        guard elapsedSeconds <= maximumGapSeconds else {
            return .rebaseline(reason: .staleGap)
        }
        guard current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else {
            return .rebaseline(reason: .counterWentBackwards)
        }

        let download = Self.megabitsPerSecond(
            bytes: current.receivedBytes - previous.receivedBytes,
            elapsedSeconds: elapsedSeconds
        )
        let upload = Self.megabitsPerSecond(
            bytes: current.sentBytes - previous.sentBytes,
            elapsedSeconds: elapsedSeconds
        )
        guard download <= Self.sanityCeilingMbps, upload <= Self.sanityCeilingMbps else {
            return .rebaseline(reason: .implausibleRate)
        }
        return .rate(downloadMbps: download, uploadMbps: upload)
    }

    private static func megabitsPerSecond(bytes: UInt64, elapsedSeconds: Double) -> Double {
        Double(bytes) * 8 / 1_000_000 / elapsedSeconds
    }
}
