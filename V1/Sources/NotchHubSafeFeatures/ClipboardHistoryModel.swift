import AppKit
import Foundation
import Observation
import OSLog

public struct ClipboardEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let copiedAt: Date

    public init(id: UUID = UUID(), text: String, copiedAt: Date = .now) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
    }

    public var preview: String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(120))
    }
}

public enum ClipboardIssue: Sendable, Equatable, Identifiable {
    case unsupportedContent
    case contentTruncated(maximumCharacters: Int)
    case contentTooLarge(maximumBytes: Int)
    case writeFailed

    public var id: String {
        switch self {
        case .unsupportedContent: "unsupported-content"
        case .contentTruncated: "content-truncated"
        case .contentTooLarge: "content-too-large"
        case .writeFailed: "write-failed"
        }
    }

    public var message: String {
        switch self {
        case .unsupportedContent:
            "That clipboard item is not readable text, so it was not retained."
        case let .contentTruncated(maximumCharacters):
            "The clipboard item was limited to \(maximumCharacters.formatted()) characters."
        case let .contentTooLarge(maximumBytes):
            "The clipboard item exceeded \(maximumBytes.formatted()) bytes, so it was not retained."
        case .writeFailed:
            "NotchHub could not restore that item to the clipboard."
        }
    }
}

public enum ClipboardReadResult: Sendable, Equatable {
    case textData(Data)
    case oversized
    case unreadable
}

public struct ClipboardReadSnapshot: Sendable, Equatable {
    public let startChangeCount: Int
    public let endChangeCount: Int
    public let typeNamesBeforeRead: [String]
    public let typeNamesAfterRead: [String]
    public let result: ClipboardReadResult

    public var isStable: Bool {
        startChangeCount == endChangeCount
    }
}

public protocol ClipboardAccess: Sendable {
    func currentChangeCount() async -> Int
    func readSnapshot(
        after changeCount: Int,
        maximumBytes: Int,
        privateTypeNames: Set<String>
    ) async -> ClipboardReadSnapshot?
    func replaceWithString(_ value: String) async -> Bool
}

public actor SystemClipboardAccess: ClipboardAccess {
    public init() {}

    public func currentChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    public func readSnapshot(
        after changeCount: Int,
        maximumBytes: Int,
        privateTypeNames: Set<String>
    ) -> ClipboardReadSnapshot? {
        let pasteboard = NSPasteboard.general
        let startChangeCount = pasteboard.changeCount
        guard startChangeCount != changeCount else { return nil }
        let typeNamesBeforeRead = pasteboard.types?.map(\.rawValue) ?? []
        let shouldRead = privateTypeNames.isDisjoint(with: typeNamesBeforeRead)
        let result = shouldRead ? readTextData(from: pasteboard, maximumBytes: maximumBytes) : .unreadable
        let typeNamesAfterRead = pasteboard.types?.map(\.rawValue) ?? []

        return ClipboardReadSnapshot(
            startChangeCount: startChangeCount,
            endChangeCount: pasteboard.changeCount,
            typeNamesBeforeRead: typeNamesBeforeRead,
            typeNamesAfterRead: typeNamesAfterRead,
            result: result
        )
    }

    public func replaceWithString(_ value: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    private func readTextData(from pasteboard: NSPasteboard, maximumBytes: Int) -> ClipboardReadResult {
        guard maximumBytes > 0, let data = pasteboard.data(forType: .string) else {
            return .unreadable
        }
        guard data.count <= maximumBytes else { return .oversized }
        return .textData(data)
    }
}

@MainActor
@Observable
public final class ClipboardHistoryModel {
    public static let defaultHistoryLimit = 12
    public static let maximumHistoryLimit = 50
    public static let maximumCharacterCount = 20000
    public static let maximumByteCount = 80000
    public static let maximumSampleRetries = 3

    public private(set) var entries: [ClipboardEntry] = []
    public private(set) var lastIssue: ClipboardIssue?
    public private(set) var isEnabled = false

    @ObservationIgnored private let access: any ClipboardAccess
    @ObservationIgnored private let historyLimit: Int
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sanitizer = ClipboardTextSanitizer()
    @ObservationIgnored private var lastChangeCount: Int?
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var retryingChangeCount: Int?
    @ObservationIgnored private var retryAttempts = 0
    @ObservationIgnored private var timer: Timer?

    private static let ignoredTypeNames: Set<String> = [
        "org.nspasteboard.AutoGeneratedType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]
    private static let logger = Logger(subsystem: "com.notchhub.v1", category: "SafeClipboard")

    public init(
        access: any ClipboardAccess = SystemClipboardAccess(),
        historyLimit: Int = ClipboardHistoryModel.defaultHistoryLimit,
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.access = access
        self.historyLimit = min(max(1, historyLimit), Self.maximumHistoryLimit)
        self.now = now
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        if isEnabled {
            startPolling()
        }
    }

    public func stop() {
        isRunning = false
        disable()
    }

    public func enable() async {
        guard !isEnabled else { return }
        captureGeneration &+= 1
        let generation = captureGeneration
        clearRetry()
        lastIssue = nil
        isEnabled = true
        let initialChangeCount = await access.currentChangeCount()
        guard isEnabled, captureGeneration == generation else { return }
        lastChangeCount = initialChangeCount
        if isRunning {
            startPolling()
        }
    }

    public func disable() {
        captureGeneration &+= 1
        isEnabled = false
        timer?.invalidate()
        timer = nil
        lastChangeCount = nil
        entries.removeAll(keepingCapacity: false)
        lastIssue = nil
        clearRetry()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func sample() async {
        guard isEnabled, !isSampling, let lastChangeCount else { return }
        isSampling = true
        let generation = captureGeneration
        defer { isSampling = false }

        guard let snapshot = await access.readSnapshot(
            after: lastChangeCount,
            maximumBytes: Self.maximumByteCount,
            privateTypeNames: Self.ignoredTypeNames
        ) else { return }
        guard isEnabled, captureGeneration == generation, snapshot.isStable else { return }
        guard !containsPrivateMarker(in: snapshot) else {
            markSeen(snapshot.endChangeCount)
            return
        }
        guard await isCurrentSnapshot(snapshot.endChangeCount, generation: generation) else { return }

        switch snapshot.result {
        case .unreadable:
            noteUnreadableChange(snapshot.endChangeCount)
        case .oversized:
            markSeen(snapshot.endChangeCount)
            lastIssue = .contentTooLarge(maximumBytes: Self.maximumByteCount)
            Self.logger.notice("Oversized clipboard text was rejected")
        case let .textData(data):
            await retain(data, changeCount: snapshot.endChangeCount, generation: generation)
        }
    }

    @discardableResult
    public func restore(_ entry: ClipboardEntry) async -> Bool {
        guard isEnabled, !isSampling, entries.contains(where: { $0.id == entry.id }) else {
            lastIssue = .writeFailed
            Self.logger.error("Clipboard restore rejected an entry outside the in-memory history")
            return false
        }
        isSampling = true
        let generation = captureGeneration
        defer { isSampling = false }
        let succeeded = await access.replaceWithString(entry.text)
        guard isEnabled, captureGeneration == generation else { return succeeded }
        guard succeeded else {
            lastIssue = .writeFailed
            Self.logger.error("Clipboard restore failed")
            return false
        }
        lastChangeCount = await access.currentChangeCount()
        clearRetry()
        lastIssue = nil
        return true
    }

    public func clear() {
        entries.removeAll(keepingCapacity: false)
        lastIssue = nil
    }

    public func dismissIssue() {
        lastIssue = nil
    }

    private func containsPrivateMarker(in snapshot: ClipboardReadSnapshot) -> Bool {
        !Self.ignoredTypeNames.isDisjoint(with: snapshot.typeNamesBeforeRead) ||
            !Self.ignoredTypeNames.isDisjoint(with: snapshot.typeNamesAfterRead)
    }

    private func retain(_ data: Data, changeCount: Int, generation: Int) async {
        let sanitized = await sanitizer.sanitize(data, maximumCharacters: Self.maximumCharacterCount)
        guard await isCurrentSnapshot(changeCount, generation: generation) else { return }
        guard let sanitized,
              !sanitized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            noteUnreadableChange(changeCount)
            return
        }
        markSeen(changeCount)
        lastIssue = sanitized.wasTruncated
            ? .contentTruncated(maximumCharacters: Self.maximumCharacterCount)
            : nil
        remember(sanitized.text)
    }

    private func isCurrentSnapshot(_ changeCount: Int, generation: Int) async -> Bool {
        guard isEnabled, captureGeneration == generation else { return false }
        let currentChangeCount = await access.currentChangeCount()
        return isEnabled && captureGeneration == generation && currentChangeCount == changeCount
    }

    private func remember(_ text: String) {
        entries.removeAll { $0.text == text }
        entries.insert(ClipboardEntry(text: text, copiedAt: now()), at: 0)
        if entries.count > historyLimit {
            entries.removeLast(entries.count - historyLimit)
        }
    }

    private func noteUnreadableChange(_ changeCount: Int) {
        if retryingChangeCount == changeCount {
            retryAttempts += 1
        } else {
            retryingChangeCount = changeCount
            retryAttempts = 1
        }
        guard retryAttempts >= Self.maximumSampleRetries else { return }
        markSeen(changeCount)
        lastIssue = .unsupportedContent
    }

    private func markSeen(_ changeCount: Int) {
        lastChangeCount = changeCount
        clearRetry()
    }

    private func clearRetry() {
        retryingChangeCount = nil
        retryAttempts = 0
    }
}
