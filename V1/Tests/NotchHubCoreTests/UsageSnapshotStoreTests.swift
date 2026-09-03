import CryptoKit
import Foundation
import Testing
@testable import NotchHubCore

private struct UsageStoreTestKeyProvider: SnapshotKeyProvider {
    func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x2A, count: 32))
    }
}

@Suite("Minimal usage snapshot storage")
struct UsageSnapshotStoreTests {
    @Test("Only provider snapshots survive a round trip")
    func roundTrip() async throws {
        try await withSnapshotDirectory { directory in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let store = UsageSnapshotStore(
                fileURL: directory.appendingPathComponent("usage.bin"),
                keyProvider: UsageStoreTestKeyProvider(),
                now: { date }
            )
            let codex = try makeSnapshot(provider: .codex, usedPercent: 20, date: date)
            let claude = try makeSnapshot(provider: .claude, usedPercent: 40, date: date)

            try await store.save([.codex: codex, .claude: claude])
            let loaded = try await store.load()

            #expect(loaded == [.codex: codex, .claude: claude])
        }
    }

    @Test("Old snapshots expire instead of forming activity history")
    func expiry() async throws {
        try await withSnapshotDirectory { directory in
            let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
            let oldDate = currentDate.addingTimeInterval(-UsageSnapshotStore.maximumRetainedAge - 1)
            let store = UsageSnapshotStore(
                fileURL: directory.appendingPathComponent("usage.bin"),
                keyProvider: UsageStoreTestKeyProvider(),
                now: { currentDate }
            )
            let oldSnapshot = try makeSnapshot(provider: .codex, usedPercent: 20, date: oldDate)

            try await store.save([.codex: oldSnapshot])
            #expect(try await store.load().isEmpty)
        }
    }

    private func makeSnapshot(
        provider: ProviderID,
        usedPercent: Double,
        date: Date
    ) throws -> UsageSnapshot {
        try UsageSnapshot(
            provider: provider,
            windows: [
                try QuotaWindow(
                    id: "\(provider.rawValue).primary",
                    label: "Primary",
                    usedPercent: usedPercent
                ),
            ],
            capturedAt: date
        )
    }
}

private func withSnapshotDirectory<T: Sendable>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchHubUsageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
        let result = try await operation(directory)
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        let operationError = error
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw error
        }
        throw operationError
    }
}
