import Darwin
import Foundation
import OSLog

enum AdapterEvent: Equatable, Sendable {
    case line(String)
    case discardedOutput
    case exited(status: Int32)
}

protocol AdapterProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

struct AdapterStreamSession: Sendable {
    let handle: any AdapterProcessHandle
    let events: AsyncStream<AdapterEvent>
}

struct AdapterCommandSession: Sendable {
    let handle: any AdapterProcessHandle
    let statuses: AsyncStream<Int32>
}

protocol AdapterLaunching: Sendable {
    func launchStream(arguments: [String]) throws -> AdapterStreamSession
    func launchCommand(arguments: [String]) throws -> AdapterCommandSession
}

struct AdapterProcessLauncher: AdapterLaunching, Sendable {
    let paths: AdapterLocator.Paths

    private static let logger = Logger(subsystem: "com.notchhub.v1", category: "MediaProcess")

    func launchStream(arguments: [String]) throws -> AdapterStreamSession {
        let process = configuredProcess(arguments: arguments)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let (events, continuation) = AsyncStream.makeStream(
            of: AdapterEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let accumulator = LineAccumulator()
        let gate = DispatchGroup()
        let exitStatus = ExitStatusBox()
        let outputReader = SendableFileHandle(output.fileHandleForReading)
        let errorReader = SendableFileHandle(errors.fileHandleForReading)
        gate.enter()
        gate.enter()
        gate.enter()

        process.terminationHandler = { finished in
            exitStatus.record(finished.terminationStatus)
            gate.leave()
        }
        try Self.runStreamProcess(
            process,
            output: output,
            errors: errors,
            gate: gate,
            continuation: continuation
        )

        Self.readOutput(outputReader, accumulator: accumulator, continuation: continuation, gate: gate)
        Self.drainErrors(errorReader, gate: gate)
        gate.notify(queue: .global(qos: .utility)) {
            if let tail = accumulator.flush() {
                Self.yield(tail, to: continuation)
            }
            continuation.yield(.exited(status: exitStatus.value))
            continuation.finish()
        }
        return AdapterStreamSession(handle: RunningProcess(process), events: events)
    }

    private static func runStreamProcess(
        _ process: Process,
        output: Pipe,
        errors: Pipe,
        gate: DispatchGroup,
        continuation: AsyncStream<AdapterEvent>.Continuation
    ) throws {
        do {
            try process.run()
            closeWriter(output.fileHandleForWriting, label: "stdout")
            closeWriter(errors.fileHandleForWriting, label: "stderr")
        } catch {
            process.terminationHandler = nil
            gate.leave()
            gate.leave()
            gate.leave()
            continuation.finish()
            closeAfterLaunchFailure(output)
            closeAfterLaunchFailure(errors)
            throw error
        }
    }

    func launchCommand(arguments: [String]) throws -> AdapterCommandSession {
        let process = configuredProcess(arguments: arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (statuses, continuation) = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.finish()
            throw error
        }
        return AdapterCommandSession(handle: RunningProcess(process), statuses: statuses)
    }

    private func configuredProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.perl)
        process.arguments = [paths.script, paths.framework] + arguments
        process.environment = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
        ]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private static func readOutput(
        _ boxedHandle: SendableFileHandle,
        accumulator: LineAccumulator,
        continuation: AsyncStream<AdapterEvent>.Continuation,
        gate: DispatchGroup
    ) {
        Thread.detachNewThread {
            let handle = boxedHandle.value
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let result = accumulator.append(data)
                for line in result.lines { yield(line, to: continuation) }
                if result.discarded { continuation.yield(.discardedOutput) }
            }
            closeReader(handle, label: "stdout")
            gate.leave()
        }
    }

    private static func drainErrors(_ boxedHandle: SendableFileHandle, gate: DispatchGroup) {
        Thread.detachNewThread {
            let handle = boxedHandle.value
            var sawOutput = false
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                sawOutput = true
            }
            if sawOutput {
                logger.warning("The media adapter wrote redacted diagnostic output")
            }
            closeReader(handle, label: "stderr")
            gate.leave()
        }
    }

    private static func yield(
        _ line: String,
        to continuation: AsyncStream<AdapterEvent>.Continuation
    ) {
        // The stream keeps the newest snapshots by design. When a slow consumer
        // drops an obsolete one, no untrusted payload is logged or accumulated.
        _ = continuation.yield(.line(line))
    }

    private static func closeWriter(_ handle: FileHandle, label: String) {
        do {
            try handle.close()
        } catch {
            logger.error("Could not close the media adapter \(label, privacy: .public) writer")
        }
    }

    private static func closeReader(_ handle: FileHandle, label: String) {
        do {
            try handle.close()
        } catch {
            logger.error("Could not close the media adapter \(label, privacy: .public) reader")
        }
    }

    private static func closeAfterLaunchFailure(_ pipe: Pipe) {
        closeWriter(pipe.fileHandleForWriting, label: "failed-launch")
        closeReader(pipe.fileHandleForReading, label: "failed-launch")
    }
}

private final class RunningProcess: AdapterProcessHandle, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminationRequested = false

    init(_ process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        let shouldTerminate = lock.withLock {
            guard !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        guard shouldTerminate, process.isRunning else { return }

        let processIdentifier = process.processIdentifier
        guard kill(processIdentifier, SIGTERM) == 0 || errno == ESRCH else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let deadline = ContinuousClock.now + .milliseconds(300)
            while process.isRunning, ContinuousClock.now < deadline {
                usleep(10_000)
            }
            if process.isRunning, process.processIdentifier == processIdentifier {
                kill(processIdentifier, SIGKILL)
            }
        }
    }
}

private struct SendableFileHandle: @unchecked Sendable {
    let value: FileHandle

    init(_ value: FileHandle) {
        self.value = value
    }
}

private final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = -1

    func record(_ status: Int32) {
        lock.withLock { self.status = status }
    }

    var value: Int32 {
        lock.withLock { status }
    }
}

struct LineAccumulatorResult: Equatable {
    let lines: [String]
    let discarded: Bool
}

final class LineAccumulator: @unchecked Sendable {
    static let maximumBufferedBytes = 64 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var isDiscardingOversizedLine = false

    func append(_ data: Data) -> LineAccumulatorResult {
        lock.withLock {
            var lines: [String] = []
            var discarded = false

            func consume(_ bytes: Data.SubSequence, completesLine: Bool) {
                if isDiscardingOversizedLine {
                    if completesLine { isDiscardingOversizedLine = false }
                    return
                }
                guard buffer.count + bytes.count <= Self.maximumBufferedBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    isDiscardingOversizedLine = !completesLine
                    discarded = true
                    return
                }
                buffer.append(contentsOf: bytes)
                guard completesLine else { return }
                defer { buffer.removeAll(keepingCapacity: true) }
                guard !buffer.isEmpty else { return }
                guard let line = String(data: buffer, encoding: .utf8) else {
                    discarded = true
                    return
                }
                lines.append(line)
            }

            var start = data.startIndex
            while start < data.endIndex,
                  let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
                consume(data[start ..< newline], completesLine: true)
                start = data.index(after: newline)
            }
            if start < data.endIndex {
                consume(data[start...], completesLine: false)
            }
            return LineAccumulatorResult(lines: lines, discarded: discarded)
        }
    }

    func flush() -> String? {
        lock.withLock {
            defer { buffer.removeAll(keepingCapacity: false) }
            guard !isDiscardingOversizedLine, !buffer.isEmpty else {
                isDiscardingOversizedLine = false
                return nil
            }
            return String(data: buffer, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
