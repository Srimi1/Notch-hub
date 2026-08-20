import Foundation
import SQLite3
import Testing
@testable import NotchHub

// Uses swift-testing (`import Testing`). Exercises the SQLite reader that backs the
// AI Coding module against throwaway fixture databases shaped like the real
// `hermes-notify` `state.db` (table `events`).
@Suite("AICoding")
struct AICodingServiceTests {

    private struct FixtureEvent {
        let source: String
        let project: String
        let type: String
        let payload: String?
        let sentAt: Double
        let status: String
    }

    /// Build a throwaway hermes-notify-shaped SQLite db from the given events and
    /// return its path.
    private func makeFixtureDB(_ events: [FixtureEvent]) -> String {
        let path = NSTemporaryDirectory() + "notchhub-test-\(UUID().uuidString).db"

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL, project TEXT NOT NULL, type TEXT NOT NULL,
            content_hash TEXT NOT NULL, payload TEXT, sent_at REAL NOT NULL, status TEXT NOT NULL
        );
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        for event in events {
            let payloadSQL = event.payload
                .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
            let sql = """
            INSERT INTO events (source, project, type, content_hash, payload, sent_at, status)
            VALUES (
                '\(event.source)','\(event.project)','\(event.type)','hash',\(payloadSQL),
                \(event.sentAt),'\(event.status)'
            );
            """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        return path
    }

    private func removeFixture(at path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            Issue.record("Could not remove SQLite fixture at \(path): \(error.localizedDescription)")
        }
    }

    /// Events come back newest-first, agent/event are mapped, and the hook's own
    /// `message` from the payload is preferred over the generic fallback.
    @Test
    func parsesEventsNewestFirstAndHonorsPayloadMessage() {
        let now = 1_780_000_000.0
        let path = makeFixtureDB([
            .init(
                source: "claude", project: "alpha", type: "complete", payload: nil,
                sentAt: now - 100, status: "sent"
            ),
            .init(
                source: "kimi", project: "beta", type: "approval",
                payload: "{\"message\":\"Needs your approval\"}", sentAt: now, status: "sent"
            )
        ])
        defer { removeFixture(at: path) }

        let logs = AICodingService().loadRecentEvents(from: path)

        #expect(logs != nil)
        #expect(logs?.count == 2)

        // Newest first.
        #expect(logs?.first?.project == "beta")
        #expect(logs?.first?.agent == "Kimi")
        #expect(logs?.first?.rawSource == "kimi") // raw token preserved for the hook
        #expect(logs?.first?.event == "approval")
        #expect(logs?.first?.message == "Needs your approval") // payload message preferred

        // Oldest carries the generic message for its type.
        #expect(logs?.last?.agent == "Claude Code")
        #expect(logs?.last?.rawSource == "claude") // display name mapped, raw token kept
        #expect(logs?.last?.message == "Task completed")
    }

    /// Suppressed/deduped events are still real state transitions and must surface
    /// in the feed — the reader filters on nothing, the UI layer interprets status.
    @Test
    func includesSuppressedEvents() {
        let path = makeFixtureDB([
            .init(
                source: "claude", project: "gamma", type: "complete",
                payload: nil, sentAt: 1_780_000_000, status: "suppressed_type"
            )
        ])
        defer { removeFixture(at: path) }

        let logs = AICodingService().loadRecentEvents(from: path)
        #expect(logs?.count == 1)
    }

    /// ASI09 hardening: a poisoned `message` from an AI agent's payload is
    /// neutralised before it reaches the UI / notifications — terminal escapes
    /// and newlines become spaces, the invisible Unicode tag block (U+E0000–
    /// U+E007F, used for ASCII smuggling) is dropped, and length is capped.
    @Test
    func sanitizesPoisonedPayloadMessage() throws {
        // "Hello" + ESC + "[31m" + tag-block char (ASCII smuggling) + newline + tab + "world"
        let smuggled = "Hello\u{1B}[31m\u{E0001}\n\tworld"
        let payloadData = try JSONSerialization.data(withJSONObject: ["message": smuggled])
        let payload = try #require(String(data: payloadData, encoding: .utf8))
        let path = makeFixtureDB([
            .init(
                source: "kimi", project: "x", type: "approval",
                payload: payload, sentAt: 1, status: "sent"
            )
        ])
        defer { removeFixture(at: path) }

        let msg = AICodingService().loadRecentEvents(from: path)?.first?.message ?? ""

        #expect(!msg.unicodeScalars.contains { $0.value == 0x1B }) // ESC stripped
        #expect(!msg.unicodeScalars.contains { $0.value == 0x09 }) // tab stripped
        #expect(!msg.contains("\n")) // newline stripped
        #expect(!msg.unicodeScalars.contains { $0.value == 0xE0001 }) // tag char dropped
        #expect(msg == "Hello [31m world") // visible text preserved, spaces collapsed
    }

    /// A very long agent message can't flood the notch / a notification body.
    @Test
    func capsOverlongPayloadMessage() throws {
        let huge = String(repeating: "A", count: 5000)
        let payloadData = try JSONSerialization.data(withJSONObject: ["message": huge])
        let payload = try #require(String(data: payloadData, encoding: .utf8))
        let path = makeFixtureDB([
            .init(
                source: "claude", project: "x", type: "attention",
                payload: payload, sentAt: 1, status: "sent"
            )
        ])
        defer { removeFixture(at: path) }

        let msg = AICodingService().loadRecentEvents(from: path)?.first?.message ?? ""
        #expect(msg.count == 200)
    }

    /// A missing database is honest "no data" (`nil`), never fabricated content.
    @Test
    func missingDatabaseYieldsNil() {
        let path = NSTemporaryDirectory() + "does-not-exist-\(UUID().uuidString).db"
        #expect(AICodingService().loadRecentEvents(from: path) == nil)
    }

    /// An existing but empty store yields `[]` (distinct from missing → `nil`).
    @Test
    func emptyDatabaseYieldsEmptyArray() {
        let path = makeFixtureDB([])
        defer { removeFixture(at: path) }

        let logs = AICodingService().loadRecentEvents(from: path)
        #expect(logs != nil)
        #expect(logs?.isEmpty == true)
    }
}
