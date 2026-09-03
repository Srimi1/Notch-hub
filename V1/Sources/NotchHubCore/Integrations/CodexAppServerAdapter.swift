import Darwin
@preconcurrency import Foundation

public struct CodexAppServerAdapter: UsageProviderAdapter {
    public let provider = ProviderID.codex

    private let executableURL: URL
    private let timeout: TimeInterval
    private let environment: [String: String]

    public init(
        executableURL: URL,
        timeout: TimeInterval = 15,
        environment: [String: String] = CodexEnvironment.minimumInherited()
    ) {
        self.executableURL = executableURL
        self.timeout = min(max(timeout, 1), 15)
        self.environment = environment
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let executable = try ExecutableSecurityValidator.validated(executableURL)
        let timeout = timeout
        let environment = CodexEnvironment.addingExecutableDirectory(
            to: environment,
            executableURL: executable
        )
        let operation = Task.detached(priority: .utility) {
            try CodexAppServerExchange.perform(
                executableURL: executable,
                environment: environment,
                timeout: timeout
            )
        }
        let response = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        return try CodexRateLimitDecoder.snapshot(from: response, capturedAt: Date())
    }
}

public enum CodexEnvironment {
    public static func minimumInherited(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let allowedKeys = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "CODEX_HOME",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "no_proxy",
        ]
        var result: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": source["LANG"] ?? "en_US.UTF-8",
        ]
        for key in allowedKeys {
            if let value = source[key], !value.contains("\0") {
                result[key] = value
            }
        }
        return result
    }

    static func addingExecutableDirectory(
        to environment: [String: String],
        executableURL: URL
    ) -> [String: String] {
        let directory = executableURL.deletingLastPathComponent().standardizedFileURL.path
        guard directory.hasPrefix("/"), !directory.contains(":"), !directory.contains("\0") else {
            return environment
        }
        var result = environment
        let basePath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        result["PATH"] = "\(directory):\(basePath)"
        return result
    }
}

enum ExecutableSecurityValidator {
    static func validated(_ candidate: URL) throws -> URL {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw ProviderError.cliNotFound(provider: .codex)
        }
        let launchURL = candidate.standardizedFileURL
        let resolved = launchURL.resolvingSymlinksInPath().standardizedFileURL
        var status = stat()
        guard lstat(resolved.path, &status) == 0 else {
            throw ProviderError.cliNotFound(provider: .codex)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
        else {
            throw ProviderError.cliNotFound(provider: .codex)
        }
        guard status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ProviderError.invalidPayload(provider: .codex, field: "executable permissions")
        }
        guard status.st_uid == geteuid() || status.st_uid == 0 else {
            throw ProviderError.invalidPayload(provider: .codex, field: "executable ownership")
        }
        return launchURL
    }
}
