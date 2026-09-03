import Foundation

public actor UsageSnapshotStore {
    public static let schemaVersion = 1
    public static let maximumRetainedAge: TimeInterval = 7 * 24 * 60 * 60

    private let encryptedStore: EncryptedCodableStore<PersistedUsageEnvelope>
    private let now: @Sendable () -> Date

    public init(
        fileURL: URL,
        keyProvider: any SnapshotKeyProvider = KeychainSnapshotKeyProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        encryptedStore = EncryptedCodableStore(
            fileURL: fileURL,
            keyProvider: keyProvider,
            maximumBytes: 262_144
        )
        self.now = now
    }

    public func load() async throws -> [ProviderID: UsageSnapshot] {
        guard let envelope = try await encryptedStore.load() else {
            return [:]
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw EncryptedStoreError.unsupportedVersion(UInt8(clamping: envelope.schemaVersion))
        }
        let cutoff = now().addingTimeInterval(-Self.maximumRetainedAge)
        var snapshots: [ProviderID: UsageSnapshot] = [:]
        for snapshot in envelope.snapshots where snapshot.capturedAt >= cutoff {
            if let existing = snapshots[snapshot.provider], existing.capturedAt >= snapshot.capturedAt {
                continue
            }
            snapshots[snapshot.provider] = snapshot
        }
        return snapshots
    }

    public func save(_ snapshots: [ProviderID: UsageSnapshot]) async throws {
        let values = snapshots.values
            .filter { $0.provider == .codex || $0.provider == .claude }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
        let envelope = PersistedUsageEnvelope(
            schemaVersion: Self.schemaVersion,
            snapshots: values
        )
        try await encryptedStore.save(envelope)
    }

    public func clear() async throws {
        try await encryptedStore.remove()
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appending(path: "Library/Application Support/NotchHub/V1", directoryHint: .isDirectory)
            .appending(path: "usage-snapshots.bin", directoryHint: .notDirectory)
    }
}

private struct PersistedUsageEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let snapshots: [UsageSnapshot]
}
