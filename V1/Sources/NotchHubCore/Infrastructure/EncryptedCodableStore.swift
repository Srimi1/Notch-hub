import CryptoKit
import Foundation

public protocol SnapshotKeyProvider: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

public enum EncryptedStoreError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unsupportedVersion(UInt8)
    case encryptionFailed
    case decryptionFailed
    case encodingFailed
    case decodingFailed
}

public actor EncryptedCodableStore<Value: Codable & Sendable> {
    private static var magic: Data {
        Data([0x4E, 0x48, 0x56, 0x31])
    }

    private let fileURL: URL
    private let keyProvider: any SnapshotKeyProvider
    private let maximumBytes: Int

    public init(
        fileURL: URL,
        keyProvider: any SnapshotKeyProvider,
        maximumBytes: Int = 1_048_576
    ) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
        self.maximumBytes = maximumBytes
    }

    public func load() throws -> Value? {
        guard let envelope = try SecureFileIO.read(
            from: fileURL,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        let sealedData = try parseEnvelope(envelope)
        let key = try keyProvider.loadOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: sealedData)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return try decode(plaintext)
        } catch let error as EncryptedStoreError {
            throw error
        } catch {
            throw EncryptedStoreError.decryptionFailed
        }
    }

    public func save(_ value: Value) throws {
        let plaintext = try encode(value)
        let key = try keyProvider.loadOrCreateKey()
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else {
                throw EncryptedStoreError.encryptionFailed
            }
            var envelope = Self.magic
            envelope.append(1)
            envelope.append(combined)
            guard envelope.count <= maximumBytes else {
                throw SecureFileIOError.oversizedFile(maximumBytes: maximumBytes)
            }
            try SecureFileIO.writeAtomically(envelope, to: fileURL)
        } catch let error as EncryptedStoreError {
            throw error
        } catch let error as SecureFileIOError {
            throw error
        } catch {
            throw EncryptedStoreError.encryptionFailed
        }
    }

    public func remove() throws {
        try SecureFileIO.remove(from: fileURL)
    }

    private func parseEnvelope(_ data: Data) throws -> Data {
        let headerSize = Self.magic.count + 1
        guard data.count > headerSize, data.prefix(Self.magic.count) == Self.magic else {
            throw EncryptedStoreError.invalidEnvelope
        }
        let version = data[Self.magic.count]
        guard version == 1 else {
            throw EncryptedStoreError.unsupportedVersion(version)
        }
        return data.dropFirst(headerSize)
    }

    private func encode(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw EncryptedStoreError.encodingFailed
        }
    }

    private func decode(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw EncryptedStoreError.decodingFailed
        }
    }
}
