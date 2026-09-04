import Foundation
import Security

enum AdapterLocator {
    static let perlPath = "/usr/bin/perl"
    static let scriptName = "mediaremote-adapter.pl"
    static let frameworkName = "MediaRemoteAdapter.framework"

    struct Paths: Equatable, Sendable {
        let perl: String
        let script: String
        let framework: String
    }

    static func locate(
        bundle: Bundle = .main,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        signatureIsValid: (URL) -> Bool = validCodeSignature
    ) -> Paths? {
        guard isExecutable(perlPath),
              let resources = bundle.resourceURL,
              let frameworks = bundle.privateFrameworksURL
        else { return nil }

        let script = resources.appendingPathComponent(scriptName, isDirectory: false)
        let framework = frameworks.appendingPathComponent(frameworkName, isDirectory: true)
        guard isConfined(script, to: resources),
              isConfined(framework, to: frameworks),
              !isSymbolicLink(script),
              !isSymbolicLink(framework),
              fileExists(script.path),
              fileExists(framework.path),
              signatureIsValid(framework)
        else { return nil }

        return Paths(perl: perlPath, script: script.path, framework: framework.path)
    }

    private static func isConfined(_ candidate: URL, to directory: URL) -> Bool {
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        } catch {
            return true
        }
    }

    private static func validCodeSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code
        else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }
}
