import Foundation

/// Compares the origin (scheme, host, port) of two URLs.
///
/// This is a pure origin comparison and nothing more — it says whether two URLs
/// address the same origin, not whether either is acceptable. The transport
/// policy (HTTPS only) lives in `SameOriginRedirectGuard`, so that a same-origin
/// check can also be used to detect "did this response come from somewhere I
/// didn't ask for?" on any scheme.
enum URLOrigin {
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              lhsScheme == rhsScheme, lhsHost == rhsHost
        else {
            return false
        }
        return effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    /// An omitted port is the scheme's default, so `https://h` and `https://h:443`
    /// are the same origin.
    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Per-task delegate that refuses any redirect leaving the request's HTTPS
/// origin. Returning `nil` from the delegate leaves the 3xx response for the
/// caller, which `APIClient` turns into a typed `unsafeRedirect` error rather
/// than silently following.
///
/// This matters because `URLSession` replays request headers across redirects:
/// following a redirect off-origin would hand the provider API key to whatever
/// host the `Location` header names.
private final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let origin = task.originalRequest?.url,
              let target = request.url,
              target.scheme?.lowercased() == "https",
              URLOrigin.isSameOrigin(origin, target)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Resilient HTTP client — the single `URLSession` owner for credit lookups.
/// 15s request timeout (CLAUDE.md max), capped backoff retry on transient
/// failures (429/5xx/timeout/connection-lost), and **no** retry on auth/client
/// errors. An `actor` so it's `Sendable` and serialises access to its session.
///
/// Responses are streamed and cut off at `maximumResponseBytes` rather than
/// buffered first and measured afterwards, so a hostile or misbehaving endpoint
/// cannot make the app allocate an unbounded body.
actor APIClient {

    struct Response: Sendable {
        let status: Int
        let data: Data
        /// Header names are lowercased so callers can look them up deterministically.
        let headers: [String: String]
    }

    /// Connectivity/transport failures the fetchers translate into honest tiles.
    enum HTTPError: Error, Sendable {
        case offline
        case transport
        case cancelled
        case responseTooLarge
        case unsafeRedirect
    }

    private let session: URLSession
    private let redirectGuard = SameOriginRedirectGuard()
    private static let maximumResponseBytes = 2 * 1_024 * 1_024

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 15
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.httpCookieStorage = nil
            cfg.urlCache = nil
            cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
            self.session = URLSession(configuration: cfg)
        }
    }

    func get(_ url: URL, headers: [String: String], maxRetries: Int = 2) async throws -> Response {
        try await send(url, method: "GET", headers: headers, body: nil, maxRetries: maxRetries)
    }

    func post(_ url: URL, headers: [String: String], body: Data, maxRetries: Int = 2) async throws -> Response {
        try await send(url, method: "POST", headers: headers, body: body, maxRetries: maxRetries)
    }

    private func send(
        _ url: URL, method: String, headers: [String: String], body: Data?, maxRetries: Int
    ) async throws -> Response {
        var attempt = 0
        while true {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.httpBody = body
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

                let (stream, response) = try await session.bytes(for: request, delegate: redirectGuard)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0

                // Decide on the status line before reading a single body byte,
                // so a retry never buffers a body it is about to discard.
                if Self.isRetryable(status: status), attempt < maxRetries {
                    stream.task.cancel()
                    attempt += 1
                    try await Self.backoff(attempt)
                    continue
                }
                try Self.rejectUnsafeRedirect(status: status, requested: url, final: http?.url, stream: stream)

                let data = try await readBody(of: stream, expecting: response.expectedContentLength)
                return Response(status: status, data: data, headers: Self.lowercasedHeaders(http))
            } catch is CancellationError {
                throw HTTPError.cancelled
            } catch let error as URLError {
                if error.code == .cancelled {
                    throw HTTPError.cancelled
                }
                if Self.isRetryable(error), attempt < maxRetries {
                    attempt += 1
                    try await Self.backoff(attempt)
                    continue
                }
                throw Self.isOffline(error) ? HTTPError.offline : HTTPError.transport
            }
        }
    }

    /// Streams the body, refusing it the moment it exceeds the cap. A declared
    /// `Content-Length` over the cap is rejected before any bytes are read.
    private func readBody(
        of stream: URLSession.AsyncBytes, expecting expectedLength: Int64
    ) async throws -> Data {
        guard expectedLength <= Int64(Self.maximumResponseBytes) else {
            stream.task.cancel()
            throw HTTPError.responseTooLarge
        }

        var buffer = [UInt8]()
        buffer.reserveCapacity(Int(max(0, min(expectedLength, Int64(Self.maximumResponseBytes)))))
        for try await byte in stream {
            guard buffer.count < Self.maximumResponseBytes else {
                stream.task.cancel()
                throw HTTPError.responseTooLarge
            }
            buffer.append(byte)
        }
        return Data(buffer)
    }

    /// A 3xx that reaches this point was *not* followed — the redirect guard
    /// refused it. A final URL on a different origin is a second, defensive
    /// check in case the session ever redirected without consulting the guard.
    private static func rejectUnsafeRedirect(
        status: Int, requested: URL, final: URL?, stream: URLSession.AsyncBytes
    ) throws {
        let isRedirect = (300 ..< 400).contains(status) && status != 304
        let movedOrigin = final.map { !URLOrigin.isSameOrigin(requested, $0) } ?? false
        guard isRedirect || movedOrigin else { return }
        stream.task.cancel()
        throw HTTPError.unsafeRedirect
    }

    private static func lowercasedHeaders(_ http: HTTPURLResponse?) -> [String: String] {
        guard let http else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                out[keyString.lowercased()] = valueString
            }
        }
        return out
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 529
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }

    /// Deterministic capped backoff: ~0.5s, then ~1.0s. No randomness needed.
    private static func backoff(_ attempt: Int) async throws {
        let seconds = 0.5 * Double(attempt)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
