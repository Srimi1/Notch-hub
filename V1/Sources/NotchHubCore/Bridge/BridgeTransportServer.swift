import Foundation

public actor BridgeUnixSocketServer {
    public typealias Handler = @Sendable (BridgeRequestEnvelope) async -> BridgeTrustedDecision

    private let socketPath: String
    private let secretProvider: any BridgeSecretProviding
    private let clock: any BridgeTransportClock
    private let peerVerifier: any BridgePeerVerifying
    private let replayGuard: BridgeTransportReplayGuard
    private let connections = BridgeServerConnectionRegistry()
    private var listenerDescriptor: Int32?
    private var listenerTask: Task<Void, Error>?
    private var isServingOne = false

    public init(
        socketPath: String = BridgeTransportPaths.defaultSocketPath(),
        secretProvider: any BridgeSecretProviding = KeychainBridgeSecretStore(),
        clock: any BridgeTransportClock = SystemBridgeTransportClock(),
        peerVerifier: any BridgePeerVerifying = DarwinBridgePeerVerifier(),
        replayGuard: BridgeTransportReplayGuard = BridgeTransportReplayGuard()
    ) {
        self.socketPath = socketPath
        self.secretProvider = secretProvider
        self.clock = clock
        self.peerVerifier = peerVerifier
        self.replayGuard = replayGuard
    }

    deinit {
        listenerTask?.cancel()
        if let listenerDescriptor {
            BridgeSocketIO.closeDescriptor(listenerDescriptor)
        }
        BridgeSocketPathSecurity.removeOwnedSocket(socketPath)
    }

    public func start() throws {
        guard listenerDescriptor == nil, listenerTask == nil else {
            throw BridgeTransportError.alreadyRunning
        }
        try BridgeSocketPathSecurity.prepareServerPath(socketPath)
        let descriptor = try BridgeSocketIO.makeStreamSocket()
        do {
            try BridgeSocketIO.bindAndListen(descriptor: descriptor, path: socketPath)
            listenerDescriptor = descriptor
        } catch {
            BridgeSocketIO.closeDescriptor(descriptor)
            BridgeSocketPathSecurity.removeOwnedSocket(socketPath)
            throw error
        }
    }

    /// Runs the production accept loop. The listener task exclusively owns the
    /// listening descriptor, and every accepted descriptor is transferred to a
    /// separate connection task before another client is accepted.
    public func serve(handler: @escaping Handler) async throws {
        guard listenerTask == nil, !isServingOne else {
            throw BridgeTransportError.alreadyRunning
        }
        guard let descriptor = listenerDescriptor else {
            throw BridgeTransportError.notRunning
        }
        listenerDescriptor = nil
        let context = connectionContext()
        let path = socketPath
        let registry = connections
        let task = Task.detached {
            defer {
                BridgeSocketIO.closeDescriptor(descriptor)
                BridgeSocketPathSecurity.removeOwnedSocket(path)
            }
            try await Self.acceptConnections(
                listener: descriptor,
                context: context,
                registry: registry,
                handler: handler
            )
        }
        listenerTask = task

        do {
            try await task.value
            listenerTask = nil
            await connections.cancelAllAndWait()
        } catch {
            listenerTask = nil
            await connections.cancelAllAndWait()
            throw error
        }
    }

    public func stop() async {
        if let listenerDescriptor {
            BridgeSocketIO.closeDescriptor(listenerDescriptor)
            self.listenerDescriptor = nil
            BridgeSocketPathSecurity.removeOwnedSocket(socketPath)
        }
        if let listenerTask {
            listenerTask.cancel()
            self.listenerTask = nil
            switch await listenerTask.result {
            case .success:
                break
            case let .failure(error):
                if let transportError = error as? BridgeTransportError, transportError == .cancelled {
                    break
                }
            }
        }
        await connections.cancelAllAndWait()
    }

    public func recentConnectionFailures() async -> [BridgeTransportError] {
        await connections.failures()
    }

    @discardableResult
    public func serveOne(
        acceptTimeoutMilliseconds: Int64 = BridgeTransportConstants.maximumDeadlineMilliseconds,
        handler: @escaping Handler
    ) async throws -> BridgeResponseEnvelope {
        guard !isServingOne, listenerTask == nil else {
            throw BridgeTransportError.alreadyRunning
        }
        guard let listenerDescriptor else {
            throw BridgeTransportError.notRunning
        }
        isServingOne = true
        defer { isServingOne = false }

        let acceptDeadline = try deadline(after: acceptTimeoutMilliseconds)
        let connection = try await BridgeSocketIO.accept(
            listener: listenerDescriptor,
            deadlineMilliseconds: acceptDeadline,
            clock: clock
        )
        return try await BridgeServerConnectionProcessor(context: connectionContext()).process(
            descriptor: connection,
            initialDeadlineMilliseconds: acceptDeadline,
            handler: handler
        )
    }

    private nonisolated static func acceptConnections(
        listener: Int32,
        context: BridgeServerConnectionContext,
        registry: BridgeServerConnectionRegistry,
        handler: @escaping Handler
    ) async throws {
        while !Task.isCancelled {
            let deadlineResult = context.clock.nowMilliseconds().addingReportingOverflow(
                BridgeTransportConstants.maximumDeadlineMilliseconds
            )
            guard !deadlineResult.overflow else {
                throw BridgeTransportError.invalidDeadline
            }
            let connection = try await BridgeSocketIO.accept(
                listener: listener,
                deadlineMilliseconds: deadlineResult.partialValue,
                clock: context.clock
            )
            await registry.launch(descriptor: connection, context: context, handler: handler)
        }
        throw BridgeTransportError.cancelled
    }

    private func connectionContext() -> BridgeServerConnectionContext {
        BridgeServerConnectionContext(
            secretProvider: secretProvider,
            clock: clock,
            peerVerifier: peerVerifier,
            replayGuard: replayGuard
        )
    }

    private func deadline(after requestedMilliseconds: Int64) throws -> Int64 {
        let timeout = min(
            max(requestedMilliseconds, 1),
            BridgeTransportConstants.maximumDeadlineMilliseconds
        )
        let result = clock.nowMilliseconds().addingReportingOverflow(timeout)
        guard !result.overflow else {
            throw BridgeTransportError.invalidDeadline
        }
        return result.partialValue
    }
}

private struct BridgeServerConnectionContext: Sendable {
    let secretProvider: any BridgeSecretProviding
    let clock: any BridgeTransportClock
    let peerVerifier: any BridgePeerVerifying
    let replayGuard: BridgeTransportReplayGuard
}

private struct BridgeServerConnectionProcessor: Sendable {
    let context: BridgeServerConnectionContext

    func process(
        descriptor: Int32,
        initialDeadlineMilliseconds: Int64,
        handler: @escaping BridgeUnixSocketServer.Handler
    ) async throws -> BridgeResponseEnvelope {
        defer { BridgeSocketIO.closeDescriptor(descriptor) }
        try context.peerVerifier.verifyPeer(socketDescriptor: descriptor)
        let body = try await BridgeSocketIO.readFrameBody(
            descriptor: descriptor,
            deadlineMilliseconds: initialDeadlineMilliseconds,
            clock: context.clock
        )
        let frame = try BridgeTransportFraming.decodedRequestBody(body)
        let secret = try context.secretProvider.loadSecret()
        try BridgeTransportAuthenticator.verifyRequestFrame(frame, secret: secret)
        try await context.replayGuard.validateAndRecord(
            nonce: frame.nonce,
            issuedAtMilliseconds: frame.issuedAtMilliseconds,
            deadlineMilliseconds: frame.deadlineMilliseconds,
            nowMilliseconds: context.clock.nowMilliseconds()
        )

        let decision = await decisionBeforeDeadline(frame: frame, handler: handler)
        guard context.clock.nowMilliseconds() <= frame.deadlineMilliseconds else {
            throw BridgeTransportError.deadlineExceeded
        }
        let response = decision.response(nonce: frame.request.nonce)
        let responseFrame = try BridgeTransportAuthenticator.makeResponseFrame(
            response: response,
            transportNonce: frame.nonce,
            secret: secret
        )
        try await BridgeSocketIO.writeFrame(
            responseFrame,
            descriptor: descriptor,
            deadlineMilliseconds: frame.deadlineMilliseconds,
            clock: context.clock
        )
        return response
    }

    private func decisionBeforeDeadline(
        frame: BridgeTransportRequestFrame,
        handler: @escaping BridgeUnixSocketServer.Handler
    ) async -> BridgeTrustedDecision {
        let remaining = frame.deadlineMilliseconds - context.clock.nowMilliseconds()
        guard remaining > 0 else {
            return .abstain(.timedOut)
        }
        let latch = BridgeDecisionLatch()
        let handlerTask = Task {
            let decision = await handler(frame.request)
            await latch.resolve(decision)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining) * 1_000_000)
                await latch.resolve(.abstain(.timedOut))
            } catch is CancellationError {
                return
            } catch {
                await latch.resolve(.abstain(.timedOut))
            }
        }
        let decision = await withTaskCancellationHandler {
            await latch.wait()
        } onCancel: {
            Task {
                await latch.resolve(.abstain(.unavailable))
            }
        }
        handlerTask.cancel()
        timeoutTask.cancel()
        return decision
    }
}

private actor BridgeDecisionLatch {
    private var decision: BridgeTrustedDecision?
    private var continuation: CheckedContinuation<BridgeTrustedDecision, Never>?

    func wait() async -> BridgeTrustedDecision {
        if let decision {
            return decision
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ decision: BridgeTrustedDecision) {
        guard self.decision == nil else {
            return
        }
        self.decision = decision
        continuation?.resume(returning: decision)
        continuation = nil
    }
}

private actor BridgeServerConnectionRegistry {
    private var nextIdentifier: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var recentFailures: [BridgeTransportError] = []

    func launch(
        descriptor: Int32,
        context: BridgeServerConnectionContext,
        handler: @escaping BridgeUnixSocketServer.Handler
    ) {
        guard tasks.count < BridgeTransportConstants.maximumConcurrentConnections else {
            BridgeSocketIO.closeDescriptor(descriptor)
            recordFailure(
                .connectionLimitExceeded(limit: BridgeTransportConstants.maximumConcurrentConnections)
            )
            return
        }
        let initialDeadline = context.clock.nowMilliseconds().addingReportingOverflow(
            BridgeTransportConstants.maximumDeadlineMilliseconds
        )
        guard !initialDeadline.overflow else {
            BridgeSocketIO.closeDescriptor(descriptor)
            recordFailure(.invalidDeadline)
            return
        }
        nextIdentifier &+= 1
        let identifier = nextIdentifier
        let processor = BridgeServerConnectionProcessor(context: context)
        tasks[identifier] = Task.detached { [weak self] in
            let failure: BridgeTransportError?
            do {
                _ = try await processor.process(
                    descriptor: descriptor,
                    initialDeadlineMilliseconds: initialDeadline.partialValue,
                    handler: handler
                )
                failure = nil
            } catch let error as BridgeTransportError {
                failure = error
            } catch is CancellationError {
                failure = .cancelled
            } catch {
                failure = .unavailable
            }
            await self?.finished(identifier: identifier, failure: failure)
        }
    }

    func cancelAllAndWait() async {
        let runningTasks = Array(tasks.values)
        runningTasks.forEach { $0.cancel() }
        for task in runningTasks {
            await task.value
        }
        tasks.removeAll(keepingCapacity: false)
    }

    func failures() -> [BridgeTransportError] {
        recentFailures
    }

    private func finished(identifier: UInt64, failure: BridgeTransportError?) {
        tasks.removeValue(forKey: identifier)
        guard let failure, failure != .cancelled else {
            return
        }
        recordFailure(failure)
    }

    private func recordFailure(_ failure: BridgeTransportError) {
        recentFailures.append(failure)
        if recentFailures.count > 16 {
            recentFailures.removeFirst(recentFailures.count - 16)
        }
    }
}
