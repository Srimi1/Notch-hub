import CryptoKit
import Foundation
import Testing
@testable import NotchHubCore

private struct TestSnapshot: Codable, Equatable, Sendable {
    let provider: String
    let usedPercent: Int
    let capturedAt: Date
}

private struct FixedSnapshotKeyProvider: SnapshotKeyProvider {
    let bytes: Data

    func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: bytes)
    }
}

@Suite("Encrypted snapshot persistence")
struct PersistenceTests {
    @Test("Round trip is encrypted and deterministic at the model boundary")
    func encryptedRoundTrip() async throws {
        try await withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("snapshots.bin")
            let provider = FixedSnapshotKeyProvider(bytes: Data(repeating: 7, count: 32))
            let store = EncryptedCodableStore<TestSnapshot>(
                fileURL: fileURL,
                keyProvider: provider
            )
            let snapshot = TestSnapshot(
                provider: "codex",
                usedPercent: 42,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )

            try await store.save(snapshot)
            let loaded = try await store.load()
            #expect(loaded == snapshot)

            let raw = try #require(try SecureFileIO.read(from: fileURL, maximumBytes: 4_096))
            #expect(!raw.contains(Data("codex".utf8)))
            #expect(!raw.contains(Data("42".utf8)))
        }
    }

    @Test("Missing snapshots are a supported state")
    func missingSnapshot() async throws {
        try await withTemporaryDirectory { directory in
            let store = EncryptedCodableStore<TestSnapshot>(
                fileURL: directory.appendingPathComponent("missing.bin"),
                keyProvider: FixedSnapshotKeyProvider(bytes: Data(repeating: 3, count: 32))
            )
            let loaded = try await store.load()
            #expect(loaded == nil)
        }
    }

    @Test("Tampering fails closed")
    func tamperingFailsClosed() async throws {
        try await withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("snapshots.bin")
            let provider = FixedSnapshotKeyProvider(bytes: Data(repeating: 9, count: 32))
            let store = EncryptedCodableStore<TestSnapshot>(
                fileURL: fileURL,
                keyProvider: provider
            )
            let snapshot = TestSnapshot(
                provider: "claude",
                usedPercent: 17,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
            try await store.save(snapshot)

            var raw = try #require(try SecureFileIO.read(from: fileURL, maximumBytes: 4_096))
            raw[raw.index(before: raw.endIndex)] ^= 0x01
            try SecureFileIO.writeAtomically(raw, to: fileURL)

            await #expect(throws: EncryptedStoreError.decryptionFailed) {
                try await store.load()
            }
        }
    }

    @Test("Symbolic-link destinations are rejected")
    func symbolicLinkRejected() async throws {
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.bin")
            let link = directory.appendingPathComponent("snapshots.bin")
            try Data("untouched".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let store = EncryptedCodableStore<TestSnapshot>(
                fileURL: link,
                keyProvider: FixedSnapshotKeyProvider(bytes: Data(repeating: 5, count: 32))
            )
            let snapshot = TestSnapshot(
                provider: "codex",
                usedPercent: 1,
                capturedAt: .distantPast
            )

            await #expect(throws: SecureFileIOError.symbolicLinkRejected) {
                try await store.save(snapshot)
            }
            #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        }
    }

    @Test("Oversized files are rejected before decoding")
    func oversizedFileRejected() async throws {
        try await withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("snapshots.bin")
            try SecureFileIO.writeAtomically(Data(repeating: 1, count: 128), to: fileURL)
            let store = EncryptedCodableStore<TestSnapshot>(
                fileURL: fileURL,
                keyProvider: FixedSnapshotKeyProvider(bytes: Data(repeating: 1, count: 32)),
                maximumBytes: 64
            )

            await #expect(throws: SecureFileIOError.oversizedFile(maximumBytes: 64)) {
                try await store.load()
            }
        }
    }
}

private func withTemporaryDirectory<T: Sendable>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchHubV1Tests-\(UUID().uuidString)", isDirectory: true)
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
