// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation

public struct ContinuousNetworkTrafficTimeSource: NetworkTrafficTimeSource {
    public init() {}

    public func now() async -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, tolerance: duration / 5)
    }
}

extension Duration {
    var networkTrafficSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

extension ContinuousClock.Instant {
    func networkTrafficSeconds(since start: ContinuousClock.Instant) -> Double {
        (self - start).networkTrafficSeconds
    }
}
