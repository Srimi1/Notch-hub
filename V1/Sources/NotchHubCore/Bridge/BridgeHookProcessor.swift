import Foundation

public enum BridgeBoundedInput {
    public static func read(
        from handle: FileHandle,
        maximumBytes: Int = BridgeProtocolConstants.maximumPayloadBytes
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw BridgeProtocolError.oversizedPayload(limit: maximumBytes)
        }

        var result = Data()
        let chunkSize = 4 * 1024
        while true {
            let allowedRead = min(chunkSize, maximumBytes + 1 - result.count)
            guard allowedRead > 0 else {
                throw BridgeProtocolError.oversizedPayload(limit: maximumBytes)
            }
            let chunk = try handle.read(upToCount: allowedRead)
            guard let chunk, !chunk.isEmpty else {
                return result
            }
            result.append(chunk)
            guard result.count <= maximumBytes else {
                throw BridgeProtocolError.oversizedPayload(limit: maximumBytes)
            }
        }
    }
}

public struct BridgeHookProcessor: Sendable {
    public init() {}

    public func response(for data: Data) -> BridgeResponseEnvelope {
        do {
            let request = try BridgeCodec.decodeRequest(data)
            return .abstaining(nonce: request.nonce, reason: .awaitingTrustedResponder)
        } catch let error as BridgeProtocolError {
            return .abstaining(nonce: "invalid", reason: abstainReason(for: error))
        } catch {
            return .abstaining(nonce: "invalid", reason: .invalidInput)
        }
    }

    public func timeoutResponse(nonce: String) -> BridgeResponseEnvelope {
        let safeNonce: String
        do {
            safeNonce = try BridgeSanitizer.nonce(nonce)
        } catch {
            safeNonce = "invalid"
        }
        return .abstaining(nonce: safeNonce, reason: .timedOut)
    }

    public func unavailableResponse(nonce: String) -> BridgeResponseEnvelope {
        let safeNonce: String
        do {
            safeNonce = try BridgeSanitizer.nonce(nonce)
        } catch {
            safeNonce = "invalid"
        }
        return .abstaining(nonce: safeNonce, reason: .unavailable)
    }

    private func abstainReason(for error: BridgeProtocolError) -> BridgeAbstainReason {
        switch error {
        case let .unsupportedVersion(version) where version != BridgeProtocolConstants.currentVersion:
            .unsupportedVersion
        case .emptyPayload, .forbiddenField, .invalidIdentifier, .invalidNonce, .invalidRateLimit, .malformedPayload,
             .oversizedPayload, .unsupportedVersion:
            .invalidInput
        }
    }
}
