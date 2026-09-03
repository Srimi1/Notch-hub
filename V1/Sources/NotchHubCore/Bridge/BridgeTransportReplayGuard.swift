import Foundation

public actor BridgeTransportReplayGuard {
    private var acceptedNonces: [String: Int64] = [:]

    public init() {}

    public func validateAndRecord(
        nonce: String,
        issuedAtMilliseconds: Int64,
        deadlineMilliseconds: Int64,
        nowMilliseconds: Int64
    ) throws {
        try validateNonce(nonce)
        try validateDeadline(
            issuedAtMilliseconds: issuedAtMilliseconds,
            deadlineMilliseconds: deadlineMilliseconds,
            nowMilliseconds: nowMilliseconds
        )
        acceptedNonces = acceptedNonces.filter { $0.value >= nowMilliseconds }
        guard acceptedNonces[nonce] == nil else {
            throw BridgeTransportError.replayDetected
        }
        acceptedNonces[nonce] = deadlineMilliseconds
    }

    public func reset() {
        acceptedNonces.removeAll(keepingCapacity: false)
    }

    private func validateNonce(_ nonce: String) throws {
        let canonical: String
        do {
            canonical = try BridgeSanitizer.nonce(nonce)
        } catch {
            throw BridgeTransportError.invalidNonce
        }
        guard canonical == nonce, nonce.count == BridgeTransportConstants.nonceBytes * 2 else {
            throw BridgeTransportError.invalidNonce
        }
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard nonce.unicodeScalars.allSatisfy(hexCharacters.contains) else {
            throw BridgeTransportError.invalidNonce
        }
    }

    private func validateDeadline(
        issuedAtMilliseconds: Int64,
        deadlineMilliseconds: Int64,
        nowMilliseconds: Int64
    ) throws {
        let allowedDeadline = issuedAtMilliseconds.addingReportingOverflow(
            BridgeTransportConstants.maximumDeadlineMilliseconds
        )
        guard !allowedDeadline.overflow,
              deadlineMilliseconds > issuedAtMilliseconds,
              deadlineMilliseconds <= allowedDeadline.partialValue
        else {
            throw BridgeTransportError.invalidDeadline
        }
        let allowedFuture = nowMilliseconds.addingReportingOverflow(
            BridgeTransportConstants.maximumFutureSkewMilliseconds
        )
        guard !allowedFuture.overflow, issuedAtMilliseconds <= allowedFuture.partialValue else {
            throw BridgeTransportError.invalidDeadline
        }
        guard nowMilliseconds <= deadlineMilliseconds else {
            throw BridgeTransportError.deadlineExceeded
        }
    }
}
