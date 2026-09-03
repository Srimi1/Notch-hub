import Foundation

public actor BridgeUnixSocketClient {
    private let socketPath: String
    private let secretProvider: any BridgeSecretProviding
    private let nonceGenerator: any BridgeNonceGenerating
    private let clock: any BridgeTransportClock
    private let peerVerifier: any BridgePeerVerifying

    public init(
        socketPath: String = BridgeTransportPaths.defaultSocketPath(),
        secretProvider: any BridgeSecretProviding = KeychainBridgeSecretProvider(),
        nonceGenerator: any BridgeNonceGenerating = SecureBridgeNonceGenerator(),
        clock: any BridgeTransportClock = SystemBridgeTransportClock(),
        peerVerifier: any BridgePeerVerifying = DarwinBridgePeerVerifier()
    ) {
        self.socketPath = socketPath
        self.secretProvider = secretProvider
        self.nonceGenerator = nonceGenerator
        self.clock = clock
        self.peerVerifier = peerVerifier
    }

    public func send(
        _ request: BridgeRequestEnvelope,
        timeoutMilliseconds: Int64 = BridgeTransportConstants.maximumDeadlineMilliseconds
    ) async throws -> BridgeResponseEnvelope {
        let issuedAt = clock.nowMilliseconds()
        let timeout = min(max(timeoutMilliseconds, 1), BridgeTransportConstants.maximumDeadlineMilliseconds)
        let deadlineResult = issuedAt.addingReportingOverflow(timeout)
        guard !deadlineResult.overflow else {
            throw BridgeTransportError.invalidDeadline
        }
        let deadline = deadlineResult.partialValue
        let secret = try secretProvider.loadSecret()
        let nonce = try nonceGenerator.freshNonce()
        let frame = try BridgeTransportAuthenticator.makeRequestFrame(
            request: request,
            nonce: nonce,
            issuedAtMilliseconds: issuedAt,
            deadlineMilliseconds: deadline,
            secret: secret
        )
        return try await exchange(frame: frame, request: request, secret: secret, deadline: deadline)
    }

    private func exchange(
        frame: BridgeTransportRequestFrame,
        request: BridgeRequestEnvelope,
        secret: Data,
        deadline: Int64
    ) async throws -> BridgeResponseEnvelope {
        try BridgeSocketPathSecurity.validateClientSocket(socketPath)
        let descriptor = try BridgeSocketIO.makeStreamSocket()
        defer { BridgeSocketIO.closeDescriptor(descriptor) }

        try await BridgeSocketIO.connect(
            descriptor: descriptor,
            path: socketPath,
            deadlineMilliseconds: deadline,
            clock: clock
        )
        try peerVerifier.verifyPeer(socketDescriptor: descriptor)
        try await BridgeSocketIO.writeFrame(
            frame,
            descriptor: descriptor,
            deadlineMilliseconds: deadline,
            clock: clock
        )
        let body = try await BridgeSocketIO.readFrameBody(
            descriptor: descriptor,
            deadlineMilliseconds: deadline,
            clock: clock
        )
        let responseFrame = try BridgeTransportFraming.decodedBody(
            BridgeTransportResponseFrame.self,
            from: body,
            maximumBytes: BridgeTransportConstants.maximumFrameBytes
        )
        return try validatedResponse(
            responseFrame,
            request: request,
            transportNonce: frame.nonce,
            secret: secret,
            deadline: deadline
        )
    }

    private func validatedResponse(
        _ frame: BridgeTransportResponseFrame,
        request: BridgeRequestEnvelope,
        transportNonce: String,
        secret: Data,
        deadline: Int64
    ) throws -> BridgeResponseEnvelope {
        guard clock.nowMilliseconds() <= deadline else {
            throw BridgeTransportError.deadlineExceeded
        }
        try BridgeTransportAuthenticator.verifyResponseFrame(frame, secret: secret)
        guard frame.nonce == transportNonce, frame.response.nonce == request.nonce else {
            throw BridgeTransportError.authenticationFailed
        }
        switch frame.response.verdict {
        case .abstain:
            guard frame.response.abstainReason != nil else {
                throw BridgeTransportError.malformedFrame
            }
        case .allowOnce, .deny:
            guard frame.response.abstainReason == nil else {
                throw BridgeTransportError.malformedFrame
            }
        }
        return frame.response
    }
}
