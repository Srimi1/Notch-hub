import Foundation

/// Something the adapter process said.
enum AdapterEvent: Sendable, Equatable {
    /// One complete line of stdout — the adapter emits newline-delimited JSON.
    case line(String)
    case exited(status: Int32)
}

/// A running adapter process, seen from the outside.
protocol AdapterProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// A launched process plus the events it will produce. The stream finishes
/// after `.exited`, so a `for await` loop over it ends on its own.
struct AdapterSession {
    var handle: AdapterProcessHandle
    var events: AsyncStream<AdapterEvent>
}

/// Starting adapter processes, abstracted so tests can drive the source without
/// spawning anything.
protocol AdapterLaunching: Sendable {
    /// Long-running invocation whose stdout is streamed line by line.
    func launch(arguments: [String]) throws -> AdapterSession
    /// Fire-and-forget invocation used for transport commands, where the only
    /// thing that matters is the side effect.
    func runDetached(arguments: [String])
    /// Kill adapter processes left behind by an earlier run of this app.
    func reapStrays()
}

extension AdapterLaunching {
    func reapStrays() {}
}

/// Runs `/usr/bin/perl <script> <framework> <arguments…>`.
struct AdapterProcessLauncher: AdapterLaunching {

    let paths: AdapterLocator.Paths

    func launch(arguments: [String]) throws -> AdapterSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.perl)
        process.arguments = [paths.script, paths.framework] + arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let (stream, sink) = AsyncStream.makeStream(of: AdapterEvent.self)
        let accumulator = LineAccumulator()

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in accumulator.append(data) { sink.yield(.line(line)) }
        }

        // Upstream documents every stderr line as an error message that is only
        // fatal if the process also exits non-zero. Log them; do not act on them.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { NSLog("NotchHub media adapter: %@", trimmed) }
        }

        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if let last = accumulator.flush() { sink.yield(.line(last)) }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            sink.yield(.exited(status: finished.terminationStatus))
            sink.finish()
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            sink.finish()
            throw error
        }

        return AdapterSession(handle: RunningProcess(process: process), events: stream)
    }

    func runDetached(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.perl)
        process.arguments = [paths.script, paths.framework] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("NotchHub media adapter: could not run %@ (%@)",
                  arguments.joined(separator: " "), error.localizedDescription)
        }
    }

    /// Kill adapter processes this app left behind.
    ///
    /// A force-quit or a crash never runs `applicationWillTerminate`, and
    /// nothing reaps a `Process` child when its parent dies — so the stream
    /// keeps running, reparented to launchd, until it next tries to write and
    /// takes a SIGPIPE. Over a few crashes that is a handful of stray
    /// interpreters holding now-playing registrations. Only *our* bundled
    /// script's absolute path is matched, so nothing else on the machine is
    /// touched, and this runs before the first launch of a session, when we
    /// have no child of our own to hit.
    func reapStrays() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", Self.strayPattern(scriptPath: paths.script)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            // 0 = something was killed, 1 = nothing matched. Both are fine.
            if process.terminationStatus == 0 {
                NSLog("NotchHub media adapter: cleaned up a stray adapter from an earlier run")
            }
        } catch {
            NSLog("NotchHub media adapter: could not check for strays (%@)",
                  error.localizedDescription)
        }
    }

    /// `pkill -f` takes an extended regular expression, and a bundle path is
    /// full of characters that mean something in one — most of all in
    /// `/Applications/NotchHub.app`, where a dot would otherwise match any
    /// character. Neutralise them so the pattern matches this exact path.
    static func strayPattern(scriptPath: String) -> String {
        let metacharacters = Set(#"\^$.|?*+()[]{}"#)
        return scriptPath.map { metacharacters.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}

/// Wraps `Process`, which predates `Sendable`. Unchecked because the only two
/// members touched from another thread — `isRunning` and `terminate()` — are
/// documented as safe to call while the process runs, and this type exposes
/// nothing else.
private final class RunningProcess: AdapterProcessHandle, @unchecked Sendable {
    private let process: Process

    /// How long SIGTERM gets before SIGKILL. Long enough for an adapter that
    /// heard the signal to unwind, short enough not to stall a quit.
    private static let gracePeriod: TimeInterval = 0.3
    private static let pollInterval: useconds_t = 10_000

    init(process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }

    /// SIGTERM, then SIGKILL if it was ignored.
    ///
    /// The adapter's SIGTERM handler does nothing but `CFRunLoopStop`, and
    /// `CFRunLoopStop` on a run loop that has not started yet is a no-op — so a
    /// signal that arrives in the tens of milliseconds between the framework
    /// loading and its run loop starting is swallowed outright. Firing and
    /// forgetting left that process running with nothing able to signal it
    /// again, because the handle is dropped immediately afterwards.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(Self.gracePeriod)
        while process.isRunning, Date() < deadline {
            usleep(Self.pollInterval)
        }
        guard process.isRunning else { return }
        NSLog("NotchHub media adapter: ignored SIGTERM, killing pid %d", process.processIdentifier)
        kill(process.processIdentifier, SIGKILL)
    }
}

/// Reassembles newline-delimited output from arbitrary read chunks. A single
/// read can end mid-JSON-object; keeping the remainder is the difference
/// between parsing a track and dropping it.
final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Guards against a pathological producer: without a ceiling a stream that
    /// never emits a newline would grow until the app is killed.
    static let maximumBufferedBytes = 4 * 1024 * 1024

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        if buffer.count > Self.maximumBufferedBytes {
            NSLog("NotchHub media adapter: dropping %d unterminated bytes", buffer.count)
            buffer.removeAll(keepingCapacity: false)
            return []
        }

        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// Whatever is left when the process exits without a trailing newline.
    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let line = String(data: buffer, encoding: .utf8)
        buffer.removeAll(keepingCapacity: false)
        return line.flatMap { $0.isEmpty ? nil : $0 }
    }
}
