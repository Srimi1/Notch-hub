import Darwin
@preconcurrency import Foundation

enum CodexAppServerExchange {
    private static let maximumOutputBytes = 1_048_576

    static func perform(
        executableURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> Data {
        let process = configuredProcess(executableURL: executableURL, environment: environment)
        let pipes = ExchangePipes()
        pipes.attach(to: process)
        try launch(process)

        var resources = ExchangeResources(process: process, pipes: pipes)
        if let preparationError = pipes.closeUnusedParentEnds() {
            do {
                try resources.shutdown()
            } catch {
                throw ProviderError.processFailed(provider: .codex, exitCode: -2)
            }
            throw preparationError
        }
        var reader = BoundedLineReader(
            fileHandle: pipes.output.fileHandleForReading,
            maximumBytes: maximumOutputBytes
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)

        do {
            let response = try exchange(resources: &resources, reader: &reader, deadline: deadline)
            try resources.shutdown()
            return response
        } catch {
            let operationError = error
            do {
                try resources.shutdown()
            } catch {
                throw ProviderError.processFailed(provider: .codex, exitCode: -2)
            }
            if operationError is CancellationError {
                throw ProviderError.cancelled(provider: .codex)
            }
            throw operationError
        }
    }

    private static func configuredProcess(
        executableURL: URL,
        environment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://", "--disable", "hooks"]
        process.environment = environment
        return process
    }

    private static func launch(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            throw ProviderError.processFailed(provider: .codex, exitCode: -1)
        }
    }

    private static func exchange(
        resources: inout ExchangeResources,
        reader: inout BoundedLineReader,
        deadline: UInt64
    ) throws -> Data {
        try resources.write(try initializeRequest())
        _ = try reader.response(id: 1, deadline: deadline, process: resources.process)
        try resources.write(initializedAndRateLimitRequest())
        return try reader.response(id: 2, deadline: deadline, process: resources.process)
    }

    private static func initializeRequest() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": ["name": "notchhub", "title": "NotchHub", "version": "0.8.0"],
                    "capabilities": ["experimentalApi": false],
                ],
            ],
            options: [.sortedKeys]
        ) + Data([0x0A])
    }

    private static func initializedAndRateLimitRequest() -> Data {
        Data("{\"method\":\"initialized\"}\n{\"method\":\"account/rateLimits/read\",\"id\":2}\n".utf8)
    }
}

private struct ExchangePipes {
    let input = Pipe()
    let output = Pipe()

    func attach(to process: Process) {
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
    }

    func closeUnusedParentEnds() -> ProviderError? {
        var closeFailed = false
        do {
            try input.fileHandleForReading.close()
        } catch {
            closeFailed = true
        }
        do {
            try output.fileHandleForWriting.close()
        } catch {
            closeFailed = true
        }
        return closeFailed ? .processFailed(provider: .codex, exitCode: -9) : nil
    }
}

private struct ExchangeResources {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    private var inputClosed = false
    private var outputClosed = false

    init(process: Process, pipes: ExchangePipes) {
        self.process = process
        input = pipes.input.fileHandleForWriting
        output = pipes.output.fileHandleForReading
    }

    mutating func write(_ data: Data) throws {
        guard !inputClosed else {
            throw ProviderError.malformedResponse(provider: .codex)
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw ProviderError.processFailed(provider: .codex, exitCode: -8)
        }
    }

    mutating func shutdown() throws {
        let inputError = closeInput()
        let processError = stopProcess()
        let outputError = closeOutput()
        if inputError != nil || processError != nil || outputError != nil {
            throw ProviderError.processFailed(provider: .codex, exitCode: -4)
        }
    }

    private mutating func closeInput() -> (any Error)? {
        guard !inputClosed else { return nil }
        defer { inputClosed = true }
        do {
            try input.close()
            return nil
        } catch {
            return error
        }
    }

    private mutating func closeOutput() -> (any Error)? {
        guard !outputClosed else { return nil }
        defer { outputClosed = true }
        do {
            try output.close()
            return nil
        } catch {
            return error
        }
    }

    private func stopProcess() -> ProviderError? {
        waitForExit(until: Date().addingTimeInterval(0.4))
        if process.isRunning, let error = signalProcessGroup(SIGTERM) {
            return error
        }
        waitForExit(until: Date().addingTimeInterval(0.4))
        if process.isRunning, let error = signalProcessGroup(SIGKILL) {
            return error
        }
        process.waitUntilExit()
        return nil
    }

    private func signalProcessGroup(_ signal: Int32) -> ProviderError? {
        let processID = process.processIdentifier
        guard processID > 1 else {
            return .processFailed(provider: .codex, exitCode: -3)
        }
        let signalTarget = getpgid(processID) == processID ? -processID : processID
        guard kill(signalTarget, signal) == 0 || errno == ESRCH else {
            return .processFailed(provider: .codex, exitCode: -3)
        }
        return nil
    }

    private func waitForExit(until deadline: Date) {
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
    }
}

private struct BoundedLineReader {
    let fileHandle: FileHandle
    let maximumBytes: Int
    private var buffer = Data()
    private var pendingLines: [Data] = []
    private var receivedBytes = 0

    init(fileHandle: FileHandle, maximumBytes: Int) {
        self.fileHandle = fileHandle
        self.maximumBytes = maximumBytes
    }

    mutating func response(id: Int, deadline: UInt64, process: Process) throws -> Data {
        while true {
            while !pendingLines.isEmpty {
                let line = pendingLines.removeFirst()
                if responseID(in: line) == id {
                    return line
                }
            }
            try readAvailable(deadline: deadline, process: process)
        }
    }

    private mutating func readAvailable(deadline: UInt64, process: Process) throws {
        try checkCancellationAndDeadline(deadline)
        guard try waitForData(deadline: deadline) else { return }
        let data = try readChunk(process: process)
        receivedBytes += data.count
        guard receivedBytes <= maximumBytes else {
            throw ProviderError.malformedResponse(provider: .codex)
        }
        buffer.append(data)
        extractLines()
    }

    private func checkCancellationAndDeadline(_ deadline: UInt64) throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ProviderError.timeout(provider: .codex)
        }
    }

    private func waitForData(deadline: UInt64) throws -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = min((deadline - now) / 1_000_000, 100)
        var descriptor = pollfd(fd: fileHandle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let result = Darwin.poll(&descriptor, 1, Int32(max(remaining, 1)))
        if result < 0, errno == EINTR {
            return false
        }
        if result < 0 {
            throw ProviderError.processFailed(provider: .codex, exitCode: -5)
        }
        return result > 0
    }

    private func readChunk(process: Process) throws -> Data {
        let data: Data
        do {
            data = try fileHandle.read(upToCount: 16_384) ?? Data()
        } catch {
            throw ProviderError.processFailed(provider: .codex, exitCode: -6)
        }
        guard !data.isEmpty else {
            let status = process.isRunning ? -7 : process.terminationStatus
            throw ProviderError.processFailed(provider: .codex, exitCode: status)
        }
        return data
    }

    private mutating func extractLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                pendingLines.append(line)
            }
        }
    }

    private func responseID(in line: Data) -> Int? {
        do {
            let object = try JSONSerialization.jsonObject(with: line)
            let dictionary = object as? [String: Any]
            return (dictionary?["id"] as? NSNumber)?.intValue
        } catch {
            return nil
        }
    }
}
