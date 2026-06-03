import Combine
import Foundation
import SQLite3
import UserNotifications

/// Live status tracking for active AI coding sessions (Claude Code, Codex, Kimi, …).
/// Backed by the `state.db` SQLite store maintained by the `hermes-notify` hook system.
final class AICodingService: ObservableObject {

    enum AgentState: String {
        case idle = "Idle"
        case running = "Running"
        case needsAttention = "Needs Attention"
        case completed = "Completed"
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let agent: String // display name, e.g. "Claude Code"
        let rawSource: String // raw hook token, e.g. "claude" — what the hook keys on
        let project: String
        let event: String
        let message: String

        static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
            lhs.timestamp == rhs.timestamp && lhs.rawSource == rhs.rawSource && lhs.project == rhs.project && lhs.event == rhs.event
        }
    }

    @Published private(set) var status: AgentState = .idle
    @Published private(set) var activeAgent: String = "None"
    @Published private(set) var activeProject: String = "None"
    @Published private(set) var lastEventTime: Date? = nil
    @Published private(set) var recentLogs: [LogEntry] = []

    // Interactive approval prompt (when agent is waiting for permission)
    @Published private(set) var pendingApproval: LogEntry? = nil
    /// Set when an allow/deny decision couldn't be persisted, so the UI can tell
    /// the user it didn't go through (the prompt stays visible to retry).
    @Published private(set) var approvalError: String? = nil

    // --- NEW: Local Ollama & Cloud Limit status tracking ---
    @Published private(set) var isOllamaRunning: Bool = false
    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var ollamaVRAMUsage: String = "Offline"

    // Budget/quota figures are read from `ai_limits.json` (schema documented near
    // `limitsURL`). They stay `nil` until that file exists, so the UI shows an
    // honest "No data" state rather than fabricated numbers.
    @Published private(set) var cloudProvider: String = "Cloud API"
    @Published private(set) var cloudBudgetLimit: Double?
    @Published private(set) var cloudBudgetUsed: Double?

    @Published private(set) var claudeCodeLimit: Int?
    @Published private(set) var claudeCodeUsed: Int?
    @Published private(set) var antigravityLimit: Int?
    @Published private(set) var antigravityUsed: Int?

    private var notifiedKeys: Set<String> = []
    private var timer: Timer?

    /// Freshest event seen from a successful read. Kept so time-based decay still
    /// runs when a later read transiently fails (a stale banner must not stick).
    private var lastNewest: LogEntry?

    /// Live agent activity is read from the SQLite store written by the
    /// `hermes-notify` hook system. NotchHub only *reads* it (integration
    /// boundary; the hook side owns all writes). Relevant schema:
    ///
    /// ```sql
    /// events(source TEXT, project TEXT, type TEXT, payload TEXT, sent_at REAL, status TEXT)
    /// ```
    /// `type` is one of `complete`, `approval`, `attention`, `session_end`;
    /// `payload` is the raw hook JSON. Absent file → honest "no data" (idle).
    private let stateDBURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache/hermes-notify/state.db")

    /// Real budget/quota source — written by the `hermes-notify` hook system.
    /// NotchHub only *reads* it; the hook side owns usage tracking (integration
    /// boundary). Expected schema:
    ///
    /// ```json
    /// {
    ///   "cloud_api":  { "provider": "Anthropic", "budget_limit": 20.0, "budget_used": 4.5, "currency": "USD" },
    ///   "agent_cli": {
    ///     "claude_code": { "queries_limit": 200,    "queries_used": 68 },
    ///     "antigravity": { "tokens_limit": 500000,  "tokens_used": 125000 }
    ///   }
    /// }
    /// ```
    /// Any missing key renders as "No data" rather than a fabricated value.
    private let limitsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache/hermes-notify/ai_limits.json")

    func start() {
        guard timer == nil else { return }
        requestNotificationPermission()
        checkState()
        checkLimits()
        checkOllama()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkState()
            self?.checkLimits()
            self?.checkOllama()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Record an allow/deny decision from the notch by writing `approval_response.json`.
    /// The waiting `hermes-notify` CLI hook polls for this file to unblock — that
    /// hook-side consumer is the integration boundary (owned outside this app).
    func handleApproval(approved: Bool) {
        guard let currentPrompt = pendingApproval else { return }

        let responseURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/hermes-notify/approval_response.json")
        // Write the RAW source token (e.g. "claude"), not the display name
        // ("Claude Code"): the waiting hook correlates on `events.source`, so a
        // display label here would fail to match and leave the agent blocked.
        let response: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "agent": currentPrompt.rawSource,
            "project": currentPrompt.project,
            "approved": approved,
            "user_action": approved ? "allow" : "deny"
        ]

        // Persist the decision FIRST and only advance the UI if the waiting hook
        // will actually see it. Swallowing this write (the old `try?`) hung the
        // agent silently: the prompt vanished but nothing unblocked it. On failure
        // we keep the prompt visible and surface the error so the user can retry.
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
            try data.write(to: responseURL, options: .atomic)
        } catch {
            logError("approval write failed: \(error.localizedDescription)")
            approvalError = approved
                ? "Couldn't send Allow — check ~/.cache/hermes-notify, then retry."
                : "Couldn't send Deny — check ~/.cache/hermes-notify, then retry."
            return
        }

        approvalError = nil
        pendingApproval = nil
        status = approved ? .running : .idle
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    private func checkAndNotify(key: String, ratio: Double, name: String, limitStr: String) {
        let key80 = "\(key)_80"
        let key100 = "\(key)_100"

        if ratio >= 1.0 {
            if !notifiedKeys.contains(key100) {
                notifiedKeys.insert(key100)
                sendNotification(
                    title: "🚨 \(name) Limit Exceeded",
                    body: "You have used 100% or more of your \(name) (\(limitStr))."
                )
            }
        } else if ratio >= 0.8 {
            if !notifiedKeys.contains(key80) {
                notifiedKeys.insert(key80)
                sendNotification(
                    title: "⚠️ \(name) Approaching Limit",
                    body: "You have used \(Int(ratio * 100))% of your \(name) (\(limitStr))."
                )
            }
        } else {
            // Reset notifications if the ratio drops below thresholds
            notifiedKeys.remove(key80)
            notifiedKeys.remove(key100)
        }
    }

    /// Read the real limits file (if present) and publish honest values. Runs on
    /// the main RunLoop timer, so `@Published` assignment is already main-thread.
    /// We never create or seed this file — absence means "No data", not fake data.
    private func checkLimits() {
        guard let data = try? Data(contentsOf: limitsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            clearLimits()
            return
        }

        // Cloud API
        if let cloud = json["cloud_api"] as? [String: Any] {
            cloudProvider = cloud["provider"] as? String ?? "Cloud API"
            cloudBudgetLimit = cloud["budget_limit"] as? Double
            cloudBudgetUsed = cloud["budget_used"] as? Double
            if let used = cloudBudgetUsed, let limit = cloudBudgetLimit, limit > 0 {
                checkAndNotify(
                    key: "cloud_budget", ratio: used / limit,
                    name: "\(cloudProvider) Budget", limitStr: "$\(String(format: "%.2f", limit))"
                )
            }
        } else {
            cloudProvider = "Cloud API"
            cloudBudgetLimit = nil
            cloudBudgetUsed = nil
        }

        // Agent CLI
        let agentCli = json["agent_cli"] as? [String: Any]
        if let claude = agentCli?["claude_code"] as? [String: Any] {
            claudeCodeLimit = claude["queries_limit"] as? Int
            claudeCodeUsed = claude["queries_used"] as? Int
            if let used = claudeCodeUsed, let limit = claudeCodeLimit, limit > 0 {
                checkAndNotify(
                    key: "claude_code", ratio: Double(used) / Double(limit),
                    name: "Claude Code Quota", limitStr: "\(limit) queries"
                )
            }
        } else {
            claudeCodeLimit = nil
            claudeCodeUsed = nil
        }

        if let antigravity = agentCli?["antigravity"] as? [String: Any] {
            antigravityLimit = antigravity["tokens_limit"] as? Int
            antigravityUsed = antigravity["tokens_used"] as? Int
            if let used = antigravityUsed, let limit = antigravityLimit, limit > 0 {
                checkAndNotify(
                    key: "antigravity", ratio: Double(used) / Double(limit),
                    name: "Antigravity Token Quota", limitStr: "\(limit) tokens"
                )
            }
        } else {
            antigravityLimit = nil
            antigravityUsed = nil
        }
    }

    /// Reset all budget figures to "no data" (file absent/unreadable).
    private func clearLimits() {
        cloudProvider = "Cloud API"
        cloudBudgetLimit = nil
        cloudBudgetUsed = nil
        claudeCodeLimit = nil
        claudeCodeUsed = nil
        antigravityLimit = nil
        antigravityUsed = nil
    }

    private func checkOllama() {
        guard let url = URL(string: "http://localhost:11434/api/ps") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if error != nil {
                DispatchQueue.main.async {
                    self.isOllamaRunning = false
                    self.ollamaModels = []
                    self.ollamaVRAMUsage = "Offline"
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else {
                DispatchQueue.main.async {
                    self.isOllamaRunning = true
                    self.ollamaModels = ["No Active Models"]
                    self.ollamaVRAMUsage = "0 GB"
                }
                return
            }

            DispatchQueue.main.async {
                self.isOllamaRunning = true
                if models.isEmpty {
                    self.ollamaModels = ["No Active Models"]
                    self.ollamaVRAMUsage = "0 GB"
                } else {
                    var parsedModels: [String] = []
                    var totalVRAMBytes: Int64 = 0

                    for model in models {
                        if let name = model["name"] as? String {
                            parsedModels.append(name)
                        }
                        if let sizeVram = model["size_vram"] as? Int64 {
                            totalVRAMBytes += sizeVram
                        } else if let size = model["size"] as? Int64 {
                            totalVRAMBytes += size
                        }
                    }

                    self.ollamaModels = parsedModels
                    let vramGB = Double(totalVRAMBytes) / 1_073_741_824.0
                    self.ollamaVRAMUsage = String(format: "%.1f GB", vramGB)
                }
            }
        }
        task.resume()
    }

    /// Poll the hook system's SQLite store for recent agent events and publish
    /// the derived UI state. Runs on the main RunLoop timer, so `@Published`
    /// assignment is already main-thread.
    private func checkState() {
        // On a successful read, refresh the log list and the cached newest event.
        // `nil` means the store was absent or this tick's read failed (e.g. a
        // transient WAL lock) — we don't fabricate new data, but we STILL fall
        // through to applyState below so time-based decay keeps running against
        // the last good event. Otherwise a momentary read failure would pin a
        // stale "Running" / "Needs Attention" banner (incl. an approval prompt)
        // on screen indefinitely.
        if let topLogs = loadRecentEvents(from: stateDBURL.path).map({ Array($0.prefix(5)) }) {
            if recentLogs != topLogs {
                recentLogs = topLogs
            }
            lastNewest = topLogs.first
        }
        applyState(newest: lastNewest)
    }

    /// Map the newest event to the published agent state. `nil` means the store
    /// exists but holds no events → idle / "None".
    private func applyState(newest: LogEntry?) {
        guard let newest = newest else {
            status = .idle
            activeAgent = "None"
            activeProject = "None"
            lastEventTime = nil
            pendingApproval = nil
            return
        }

        activeAgent = newest.agent
        activeProject = newest.project
        lastEventTime = newest.timestamp

        let elapsed = Date().timeIntervalSince(newest.timestamp)

        switch newest.event {
        case "approval", "attention":
            // Show "needs attention" + the interactive prompt for 15 minutes.
            if elapsed < 900 {
                status = .needsAttention
                pendingApproval = newest
            } else {
                status = .idle
                pendingApproval = nil
            }
        case "complete":
            status = elapsed < 300 ? .completed : .idle
            pendingApproval = nil
        case "session_end":
            status = .idle
            pendingApproval = nil
        default:
            status = elapsed < 120 ? .running : .idle
            pendingApproval = nil
        }
    }

    /// Read recent agent events from a `hermes-notify` SQLite store at `path`,
    /// newest first. Returns `nil` if the database is absent or unreadable
    /// (→ honest "no data"); returns `[]` if it exists but holds no events.
    /// Opens read-only — NotchHub never writes this store. Path is injectable so
    /// the parse logic is unit-testable against a fixture database.
    func loadRecentEvents(from path: String, limit: Int32 = 50) -> [LogEntry]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logError("open failed: \(sqliteError(db))")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT source, project, type, payload, sent_at FROM events ORDER BY sent_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError("prepare failed: \(sqliteError(db))")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, limit)

        var rows: [LogEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sourceC = sqlite3_column_text(stmt, 0),
                  let projectC = sqlite3_column_text(stmt, 1),
                  let typeC = sqlite3_column_text(stmt, 2)
            else { continue }

            let source = String(cString: sourceC)
            let project = String(cString: projectC)
            let type = String(cString: typeC)
            let payload = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let sentAt = sqlite3_column_double(stmt, 4)

            rows.append(LogEntry(
                timestamp: Date(timeIntervalSince1970: sentAt),
                agent: formatAgentName(source),
                rawSource: source,
                project: project,
                event: type,
                message: formatEventMessage(event: type, payload: payload)
            ))
        }
        return rows
    }

    private func sqliteError(_ db: OpaquePointer?) -> String {
        guard let db = db else { return "unknown" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func logError(_ message: String) {
        print("[AICodingService] \(message)")
    }

    private func formatAgentName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "kimi": return "Kimi"
        case "antigravity": return "Antigravity"
        case "manual": return "CLI Manual"
        default: return raw.capitalized
        }
    }

    /// Human-readable message for an event `type`, preferring the hook's own
    /// `message` field from `payload` when present (e.g. the exact approval text).
    private func formatEventMessage(event: String, payload: String?) -> String {
        switch event {
        case "approval":
            return payloadMessage(payload) ?? "Waiting for plan approval / permission"
        case "attention":
            return payloadMessage(payload) ?? "Needs your attention"
        case "complete":
            return "Task completed"
        case "session_end":
            return "AI agent session ended"
        case "test":
            return "System notification smoke test"
        default:
            return payloadMessage(payload) ?? "Event: \(event)"
        }
    }

    /// Extract the `message` string from a hook payload JSON blob, if any.
    private func payloadMessage(_ payload: String?) -> String? {
        guard let payload = payload,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String,
              !message.isEmpty
        else { return nil }
        let clean = sanitizeForDisplay(message)
        return clean.isEmpty ? nil : clean
    }

    /// Defensive cleanup for AI-agent-authored text before it's shown in the
    /// notch or pushed into a notification (ASI09 — don't trust AI output blindly).
    /// Drops C0/DEL control characters (terminal escapes, newlines) and the
    /// invisible Unicode "tag" block U+E0000–U+E007F used for ASCII smuggling,
    /// collapses runs of spaces, and caps the length so a poisoned event store
    /// can't flood the UI or a notification body.
    private func sanitizeForDisplay(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isDefaultIgnorableCodePoint {
                continue // invisible (tag block / zero-width) — drop so visible text reconstructs
            }
            if scalar.value == 0x7F || scalar.value < 0x20 {
                out.append(" ") // C0 control / DEL (escapes, newlines, tabs) — neutralise to a space
            } else {
                out.append(scalar)
            }
        }
        let collapsed = String(out)
            .components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(200))
    }
}
