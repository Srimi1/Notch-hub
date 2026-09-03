import Foundation
import NotchHubCore

@MainActor
final class BridgeHelperInstaller {
    private let engine: BridgeHelperInstallerEngine
    private let bundle: Bundle
    private let homeDirectory: URL

    init(
        engine: BridgeHelperInstallerEngine? = nil,
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        #if DEBUG
            let signaturePolicy = BridgeHelperSignaturePolicy.development
        #else
            let hostIdentifier = bundle.bundleIdentifier ?? "com.notchhub.app"
            let signaturePolicy = BridgeHelperSignaturePolicy.release(
                expectedHostIdentifier: hostIdentifier,
                expectedHelperIdentifier: "com.notchhub.v1.bridge.helper"
            )
        #endif
        self.engine = engine ?? BridgeHelperInstallerEngine(
            signaturePolicy: signaturePolicy
        )
        self.bundle = bundle
        self.homeDirectory = homeDirectory
    }

    func install() async throws -> BridgeHelperInstallationResult {
        try await engine.install(
            sourceURL: embeddedHelperURL,
            hostBundleURL: bundle.bundleURL,
            destinationURL: installedHelperURL
        )
    }

    var installedHelperURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/NotchHub/V1/Bridge", isDirectory: true)
            .appendingPathComponent("NotchHubHookBridge", isDirectory: false)
    }

    private var embeddedHelperURL: URL {
        bundle.url(forAuxiliaryExecutable: "NotchHubHookBridge")
            ?? bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("NotchHubHookBridge", isDirectory: false)
    }
}
