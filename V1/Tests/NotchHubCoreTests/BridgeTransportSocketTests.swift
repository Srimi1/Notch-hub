import Foundation
import Testing
@testable import NotchHubBridge
@testable import NotchHubCore

@Suite("Unix socket bridge transport")
struct BridgeTransportSocketTests {
    @Test("Authenticated same-user round trip uses owner-only socket permissions")
    func roundTrip() async throws {
        let fixture = SocketFixture()
        let secret = Data(repeating: 0x6B, count: 32)
        let provider = InMemoryBridgeSecretProvider(secret: secret)
        let server = BridgeUnixSocketServer(socketPath: fixture.socketPath, secretProvider: provider)
        do {
            try await server.start()
            let serverTask = Task {
                try await server.serveOne(acceptTimeoutMilliseconds: 5_000) { _ in .allowOnce }
            }
            let client = BridgeUnixSocketClient(socketPath: fixture.socketPath, secretProvider: provider)
            let request = try fixture.request()
            let response = try await client.send(request, timeoutMilliseconds: 5_000)
            let serverResponse = try await serverTask.value

            #expect(response.verdict == .allowOnce)
            #expect(serverResponse == response)
            #expect(try fixture.permissions(at: fixture.directoryPath) == 0o700)
            #expect(try fixture.permissions(at: fixture.socketPath) == 0o600)
            await server.stop()
            fixture.cleanup()
        } catch {
            await server.stop()
            fixture.cleanup()
            throw error
        }
    }

    @Test("A pending approval does not block status-line connections")
    func concurrentConnections() async throws {
        let fixture = SocketFixture()
        let provider = InMemoryBridgeSecretProvider(secret: Data(repeating: 0x4C, count: 32))
        let server = BridgeUnixSocketServer(socketPath: fixture.socketPath, secretProvider: provider)
        let handler = BlockingApprovalHandler()
        do {
            try await server.start()
            let serveTask = Task {
                try await server.serve { request in
                    await handler.handle(request)
                }
            }
            let approvalClient = BridgeUnixSocketClient(socketPath: fixture.socketPath, secretProvider: provider)
            let approvalTask = Task {
                try await approvalClient.send(fixture.approvalRequest(), timeoutMilliseconds: 5_000)
            }
            await handler.waitUntilApprovalEntered()

            let statusClient = BridgeUnixSocketClient(socketPath: fixture.socketPath, secretProvider: provider)
            let statusResponse = try await statusClient.send(
                fixture.statusLineRequest(),
                timeoutMilliseconds: 1_000
            )
            #expect(statusResponse.verdict == .abstain)
            #expect(statusResponse.abstainReason == .awaitingTrustedResponder)

            await handler.resolveApproval(.deny)
            let approvalResponse = try await approvalTask.value
            #expect(approvalResponse.verdict == .deny)
            await server.stop()
            switch await serveTask.result {
            case .success:
                Issue.record("The bridge serve loop unexpectedly exited without cancellation")
            case let .failure(error):
                #expect(error as? BridgeTransportError == .cancelled)
            }
            fixture.cleanup()
        } catch {
            await server.stop()
            fixture.cleanup()
            throw error
        }
    }

    @Test("The server bounds concurrent same-user connections")
    func connectionLimit() async throws {
        let fixture = SocketFixture()
        let provider = InMemoryBridgeSecretProvider(secret: Data(repeating: 0x7D, count: 32))
        let server = BridgeUnixSocketServer(socketPath: fixture.socketPath, secretProvider: provider)
        let handler = CountingApprovalHandler()
        do {
            try await server.start()
            let serveTask = Task {
                try await server.serve { request in
                    await handler.handle(request)
                }
            }
            var clients: [Task<BridgeResponseEnvelope, Error>] = []
            for index in 0 ..< BridgeTransportConstants.maximumConcurrentConnections {
                let client = BridgeUnixSocketClient(socketPath: fixture.socketPath, secretProvider: provider)
                clients.append(Task {
                    try await client.send(fixture.approvalRequest(), timeoutMilliseconds: 5_000)
                })
                await handler.waitForCount(index + 1)
            }

            await expectExcessConnectionRejected(server: server, fixture: fixture, provider: provider)

            await handler.resolveAll(.deny)
            for client in clients {
                #expect(try await client.value.verdict == .deny)
            }
            await server.stop()
            _ = await serveTask.result
            fixture.cleanup()
        } catch {
            await handler.resolveAll(.deny)
            await server.stop()
            fixture.cleanup()
            throw error
        }
    }

    @Test("A transport nonce cannot be replayed across real socket connections")
    func replayRejected() async throws {
        let fixture = SocketFixture()
        let provider = InMemoryBridgeSecretProvider(secret: Data(repeating: 0x5A, count: 32))
        let nonceGenerator = FixedBridgeNonceGenerator(value: String(repeating: "e", count: 64))
        let server = BridgeUnixSocketServer(socketPath: fixture.socketPath, secretProvider: provider)
        do {
            try await server.start()
            let client = BridgeUnixSocketClient(
                socketPath: fixture.socketPath,
                secretProvider: provider,
                nonceGenerator: nonceGenerator
            )
            let firstServer = Task {
                try await server.serveOne(acceptTimeoutMilliseconds: 5_000) { _ in .allowOnce }
            }
            _ = try await client.send(fixture.request(), timeoutMilliseconds: 5_000)
            _ = try await firstServer.value

            let replayServer = Task {
                await #expect(throws: BridgeTransportError.replayDetected) {
                    try await server.serveOne(acceptTimeoutMilliseconds: 5_000) { _ in .allowOnce }
                }
            }
            await #expect(throws: (any Error).self) {
                try await client.send(fixture.request(), timeoutMilliseconds: 5_000)
            }
            _ = await replayServer.value
            await server.stop()
            fixture.cleanup()
        } catch {
            await server.stop()
            fixture.cleanup()
            throw error
        }
    }

    @Test("Wrong secret produces no authenticated verdict")
    func wrongSecret() async throws {
        let fixture = SocketFixture()
        let serverProvider = InMemoryBridgeSecretProvider(secret: Data(repeating: 0x11, count: 32))
        let clientProvider = InMemoryBridgeSecretProvider(secret: Data(repeating: 0x22, count: 32))
        let server = BridgeUnixSocketServer(socketPath: fixture.socketPath, secretProvider: serverProvider)
        do {
            try await server.start()
            let serverTask = Task {
                await #expect(throws: BridgeTransportError.authenticationFailed) {
                    try await server.serveOne(acceptTimeoutMilliseconds: 5_000) { _ in .allowOnce }
                }
            }
            let client = BridgeUnixSocketClient(socketPath: fixture.socketPath, secretProvider: clientProvider)
            await #expect(throws: (any Error).self) {
                try await client.send(fixture.request(), timeoutMilliseconds: 5_000)
            }
            _ = await serverTask.value
            await server.stop()
            fixture.cleanup()
        } catch {
            await server.stop()
            fixture.cleanup()
            throw error
        }
    }

    @Test("Existing symlink at the socket path is rejected without removal")
    func symlinkRejected() async throws {
        let fixture = SocketFixture()
        try FileManager.default.createDirectory(
            atPath: fixture.directoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(atPath: fixture.socketPath, withDestinationPath: "/tmp")
        let server = BridgeUnixSocketServer(
            socketPath: fixture.socketPath,
            secretProvider: InMemoryBridgeSecretProvider(secret: Data(repeating: 0x33, count: 32))
        )

        await #expect(throws: BridgeTransportError.socketPathConflict) {
            try await server.start()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))
        fixture.cleanup()
    }

    private func expectExcessConnectionRejected(
        server: BridgeUnixSocketServer,
        fixture: SocketFixture,
        provider: InMemoryBridgeSecretProvider
    ) async {
        let client = BridgeUnixSocketClient(socketPath: fixture.socketPath, secretProvider: provider)
        await #expect(throws: (any Error).self) {
            try await client.send(fixture.approvalRequest(), timeoutMilliseconds: 1_000)
        }
        let failures = await server.recentConnectionFailures()
        #expect(
            failures.contains(
                .connectionLimitExceeded(limit: BridgeTransportConstants.maximumConcurrentConnections)
            )
        )
    }
}

private struct FixedBridgeNonceGenerator: BridgeNonceGenerating {
    let value: String

    func freshNonce() throws -> String {
        value
    }
}

private actor BlockingApprovalHandler {
    private var approvalEntered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var decisionContinuation: CheckedContinuation<BridgeTrustedDecision, Never>?

    func handle(_ request: BridgeRequestEnvelope) async -> BridgeTrustedDecision {
        guard case .approval = request.event else {
            return .abstain(.awaitingTrustedResponder)
        }
        approvalEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        return await withCheckedContinuation { continuation in
            decisionContinuation = continuation
        }
    }

    func waitUntilApprovalEntered() async {
        if approvalEntered {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func resolveApproval(_ decision: BridgeTrustedDecision) {
        decisionContinuation?.resume(returning: decision)
        decisionContinuation = nil
    }
}

private actor CountingApprovalHandler {
    private var count = 0
    private var targetCount = Int.max
    private var countContinuation: CheckedContinuation<Void, Never>?
    private var decisionContinuations: [CheckedContinuation<BridgeTrustedDecision, Never>] = []

    func handle(_ request: BridgeRequestEnvelope) async -> BridgeTrustedDecision {
        guard case .approval = request.event else {
            return .abstain(.awaitingTrustedResponder)
        }
        count += 1
        if count >= targetCount {
            countContinuation?.resume()
            countContinuation = nil
        }
        return await withCheckedContinuation { continuation in
            decisionContinuations.append(continuation)
        }
    }

    func waitForCount(_ target: Int) async {
        targetCount = target
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countContinuation = continuation
        }
    }

    func resolveAll(_ decision: BridgeTrustedDecision) {
        let continuations = decisionContinuations
        decisionContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(returning: decision) }
    }
}

private struct SocketFixture: Sendable {
    let directoryPath: String
    let socketPath: String

    init() {
        let suffix = UUID().uuidString.prefix(12)
        directoryPath = "/tmp/notchhub-bridge-\(suffix)"
        socketPath = directoryPath + "/bridge.sock"
    }

    func request() throws -> BridgeRequestEnvelope {
        let event = try BridgeSessionEvent(
            eventID: "event-1",
            provider: .codex,
            sessionID: "session-1",
            state: .waitingForApproval,
            projectLabel: "NotchHub",
            occurredAt: Date()
        )
        return try BridgeRequestEnvelope(nonce: String(repeating: "d", count: 64), event: .session(event))
    }

    func approvalRequest() throws -> BridgeRequestEnvelope {
        let approval = try BridgeApprovalRequest(
            approvalID: "approval-1",
            provider: .codex,
            sessionID: "session-1",
            projectLabel: "NotchHub",
            actionCategory: .processExecution,
            targetLabel: "Shell",
            expiresAt: Date().addingTimeInterval(5)
        )
        return try BridgeRequestEnvelope(
            nonce: String(repeating: "a", count: 64),
            event: .approval(approval)
        )
    }

    func statusLineRequest() throws -> BridgeRequestEnvelope {
        let window = try BridgeRateLimitWindow(id: .fiveHour, usedPercent: 25, resetsAt: nil)
        let event = try BridgeStatusLineEvent(
            provider: .claude,
            sessionID: "session-2",
            rateLimits: [window],
            capturedAt: Date()
        )
        return try BridgeRequestEnvelope(
            nonce: String(repeating: "b", count: 64),
            event: .statusLine(event)
        )
    }

    func permissions(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let value = try #require(attributes[.posixPermissions] as? NSNumber)
        return value.intValue
    }

    func cleanup() {
        do {
            if FileManager.default.fileExists(atPath: directoryPath) {
                try FileManager.default.removeItem(atPath: directoryPath)
            }
        } catch {
            Issue.record("Temporary bridge fixture cleanup failed: \(error.localizedDescription)")
        }
    }
}
