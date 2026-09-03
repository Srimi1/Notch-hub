import Foundation
import Testing
@testable import NotchHubSafeFeatures

@MainActor
@Suite("Safe clipboard", .serialized)
struct ClipboardHistoryModelTests {
    @Test("History is newest-first, deduplicated, and bounded")
    func historyBoundsAndDeduplication() async {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access, historyLimit: 2)

        await copy("one", through: access, into: model)
        await copy("two", through: access, into: model)
        await copy("three", through: access, into: model)
        await copy("two", through: access, into: model)

        #expect(model.entries.map(\.text) == ["two", "three"])
        #expect(model.entries.count == 2)
    }

    @Test("Concealed and transient clipboard items are never retained")
    func privacyMarkersAreIgnored() async {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)

        access.publish(text: "password", types: ["org.nspasteboard.ConcealedType"])
        await model.sample()
        access.publish(text: "token", types: ["org.nspasteboard.TransientType"])
        await model.sample()

        #expect(model.entries.isEmpty)
        #expect(model.lastIssue == nil)
    }

    @Test("Text from a changing clipboard snapshot is never retained")
    func changingSnapshotIsRetried() async {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)
        access.publish(text: "stale value")
        access.mutateOnNextRead = { access.publish(text: "fresh value") }

        await model.sample()
        #expect(model.entries.isEmpty)

        await model.sample()
        #expect(model.entries.map(\.text) == ["fresh value"])
    }

    @Test("Capture requires opt-in and disabling clears sensitive state")
    func captureRequiresOptIn() async {
        let access = ClipboardAccessStub()
        let model = ClipboardHistoryModel(access: access)

        access.publish(text: "before opt-in")
        await model.sample()
        #expect(model.entries.isEmpty)

        await model.enable()
        access.publish(text: "after opt-in")
        await model.sample()
        #expect(model.entries.map(\.text) == ["after opt-in"])

        model.disable()
        access.publish(text: "after disabling")
        await model.sample()
        #expect(!model.isEnabled)
        #expect(model.entries.isEmpty)
    }

    @Test("Oversized text is sanitized and reports the bound")
    func oversizedTextIsBounded() async {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)
        let oversized = "\0" + String(repeating: "x", count: ClipboardHistoryModel.maximumCharacterCount + 20)

        await copy(oversized, through: access, into: model)

        #expect(model.entries.count == 1)
        #expect(model.entries[0].text.count == ClipboardHistoryModel.maximumCharacterCount)
        #expect(!model.entries[0].text.contains("\0"))
        #expect(
            model.lastIssue == .contentTruncated(
                maximumCharacters: ClipboardHistoryModel.maximumCharacterCount
            )
        )
    }

    @Test("The byte limit rejects a payload before text decoding")
    func byteLimitRejectsPayload() async {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)
        access.publish(text: "not decoded")
        access.nextReadResult = .oversized

        await model.sample()

        #expect(model.entries.isEmpty)
        #expect(model.lastIssue == .contentTooLarge(maximumBytes: ClipboardHistoryModel.maximumByteCount))
        #expect(access.requestedMaximumBytes == ClipboardHistoryModel.maximumByteCount)
    }

    @Test("Partially written clipboard changes are retried before failure")
    func unreadableContentRetries() async {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)
        access.publish(text: nil)

        for _ in 0 ..< ClipboardHistoryModel.maximumSampleRetries - 1 {
            await model.sample()
        }
        #expect(model.lastIssue == nil)

        await model.sample()
        #expect(model.lastIssue == .unsupportedContent)
        #expect(model.entries.isEmpty)
    }

    @Test("Meaningful whitespace is preserved when an item is restored")
    func whitespaceIsPreserved() async throws {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)
        await copy("  indented text\n", through: access, into: model)
        let entry = try #require(model.entries.first)

        #expect(await model.restore(entry))
        #expect(access.text == "  indented text\n")
    }

    @Test("Restore failures are visible and never ingest their own writes")
    func restoreFailureAndSuccess() async throws {
        let access = ClipboardAccessStub()
        let model = await enabledModel(access: access)
        await copy("safe value", through: access, into: model)
        let entry = try #require(model.entries.first)
        access.allowsWrites = false

        let failedRestore = await model.restore(entry)
        #expect(!failedRestore)
        #expect(model.lastIssue == .writeFailed)

        access.allowsWrites = true
        #expect(await model.restore(entry))
        await model.sample()
        #expect(model.entries.count == 1)
        #expect(access.text == "safe value")
        #expect(model.lastIssue == nil)
    }

    @Test("An entry not owned by history cannot be restored")
    func unknownEntryIsRejected() async {
        let access = ClipboardAccessStub()
        let model = ClipboardHistoryModel(access: access)

        let restored = await model.restore(ClipboardEntry(text: "outside"))
        #expect(!restored)
        #expect(access.replacementCount == 0)
        #expect(model.lastIssue == .writeFailed)
    }

    private func copy(
        _ text: String,
        through access: ClipboardAccessStub,
        into model: ClipboardHistoryModel
    ) async {
        access.publish(text: text)
        await model.sample()
    }

    private func enabledModel(
        access: ClipboardAccessStub,
        historyLimit: Int = ClipboardHistoryModel.defaultHistoryLimit
    ) async -> ClipboardHistoryModel {
        let model = ClipboardHistoryModel(access: access, historyLimit: historyLimit)
        await model.enable()
        return model
    }
}

@MainActor
private final class ClipboardAccessStub: ClipboardAccess {
    private(set) var changeCount = 0
    private(set) var availableTypeNames: [String] = []
    private(set) var text: String?
    private(set) var replacementCount = 0
    private(set) var requestedMaximumBytes: Int?
    var allowsWrites = true
    var mutateOnNextRead: (() -> Void)?
    var nextReadResult: ClipboardReadResult?

    func publish(text: String?, types: [String] = ["public.utf8-plain-text"]) {
        self.text = text
        availableTypeNames = types
        changeCount += 1
    }

    func currentChangeCount() async -> Int {
        changeCount
    }

    func readSnapshot(
        after previousChangeCount: Int,
        maximumBytes: Int,
        privateTypeNames: Set<String>
    ) async -> ClipboardReadSnapshot? {
        let startChangeCount = changeCount
        guard startChangeCount != previousChangeCount else { return nil }
        requestedMaximumBytes = maximumBytes
        let typeNamesBeforeRead = availableTypeNames
        let result = privateTypeNames.isDisjoint(with: typeNamesBeforeRead)
            ? nextReadResult ?? defaultReadResult(maximumBytes: maximumBytes)
            : .unreadable
        nextReadResult = nil
        let mutation = mutateOnNextRead
        mutateOnNextRead = nil
        mutation?()
        return ClipboardReadSnapshot(
            startChangeCount: startChangeCount,
            endChangeCount: changeCount,
            typeNamesBeforeRead: typeNamesBeforeRead,
            typeNamesAfterRead: availableTypeNames,
            result: result
        )
    }

    func replaceWithString(_ value: String) async -> Bool {
        guard allowsWrites else { return false }
        text = value
        availableTypeNames = ["public.utf8-plain-text"]
        replacementCount += 1
        changeCount += 1
        return true
    }

    private func defaultReadResult(maximumBytes: Int) -> ClipboardReadResult {
        guard let text else { return .unreadable }
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { return .oversized }
        return .textData(data)
    }
}
