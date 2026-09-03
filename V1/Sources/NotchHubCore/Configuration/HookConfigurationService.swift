import Darwin
import Foundation
import NotchHubBridge

public actor HookConfigurationService {
    private struct PendingPreview: Sendable {
        let provider: HookConfigurationProvider
        let operation: HookConfigurationOperation
        let bridgeExecutablePath: String?
        let snapshot: HookConfigurationFileSnapshot
        let plan: HookConfigurationPlan
    }

    private let homeDirectory: URL
    private let fileSystem: any HookConfigurationFileSystem
    private let planner: HookConfigurationPlanner
    private var pendingPreviews: [UUID: PendingPreview] = [:]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: any HookConfigurationFileSystem = LocalHookConfigurationFileSystem(),
        planner: HookConfigurationPlanner = HookConfigurationPlanner()
    ) {
        self.homeDirectory = homeDirectory
        self.fileSystem = fileSystem
        self.planner = planner
    }

    public func previewConnection(
        provider: HookConfigurationProvider,
        bridgeExecutablePath: String
    ) throws -> HookConfigurationConsentPreview {
        try makePreview(
            provider: provider,
            operation: .connect,
            bridgeExecutablePath: bridgeExecutablePath
        )
    }

    public func previewDisconnection(
        provider: HookConfigurationProvider
    ) throws -> HookConfigurationConsentPreview {
        try makePreview(provider: provider, operation: .disconnect, bridgeExecutablePath: nil)
    }

    public func discard(_ preview: HookConfigurationConsentPreview) {
        pendingPreviews.removeValue(forKey: preview.id)
    }

    public func apply(
        _ preview: HookConfigurationConsentPreview
    ) throws -> HookConfigurationApplicationResult {
        guard let pending = pendingPreviews.removeValue(forKey: preview.id) else {
            throw HookConfigurationApplicationError.previewUnavailable
        }
        guard pending.plan.diff == preview.diff else {
            throw HookConfigurationApplicationError.previewMismatch
        }

        let current = try inspect(provider: pending.provider)
        guard current == pending.snapshot else {
            throw HookConfigurationApplicationError.concurrentModification
        }
        let currentPlan = try plan(
            provider: pending.provider,
            operation: pending.operation,
            input: current.input,
            bridgeExecutablePath: pending.bridgeExecutablePath
        )
        guard currentPlan == pending.plan else {
            throw HookConfigurationApplicationError.concurrentModification
        }
        guard let write = currentPlan.atomicWrite else {
            return HookConfigurationApplicationResult(diff: currentPlan.diff, wroteConfiguration: false)
        }
        guard write.fileMode == 0o600,
              write.destinationPath == currentPlan.diff.destinationPath
        else {
            throw HookConfigurationApplicationError.invalidAtomicWrite
        }

        try fileSystem.replaceAtomically(
            write.data,
            provider: pending.provider,
            homeDirectory: homeDirectory,
            expected: current,
            fileMode: write.fileMode
        )
        return HookConfigurationApplicationResult(diff: currentPlan.diff, wroteConfiguration: true)
    }

    private func makePreview(
        provider: HookConfigurationProvider,
        operation: HookConfigurationOperation,
        bridgeExecutablePath: String?
    ) throws -> HookConfigurationConsentPreview {
        let snapshot = try inspect(provider: provider)
        let configurationPlan = try plan(
            provider: provider,
            operation: operation,
            input: snapshot.input,
            bridgeExecutablePath: bridgeExecutablePath
        )
        let id = UUID()
        pendingPreviews = pendingPreviews.filter { $0.value.provider != provider }
        pendingPreviews[id] = PendingPreview(
            provider: provider,
            operation: operation,
            bridgeExecutablePath: bridgeExecutablePath,
            snapshot: snapshot,
            plan: configurationPlan
        )
        return HookConfigurationConsentPreview(id: id, diff: configurationPlan.diff)
    }

    private func inspect(
        provider: HookConfigurationProvider
    ) throws -> HookConfigurationFileSnapshot {
        do {
            return try fileSystem.inspect(
                provider: provider,
                homeDirectory: homeDirectory,
                maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
            )
        } catch let error as HookConfigurationApplicationError {
            throw error
        } catch {
            throw HookConfigurationApplicationError.fileSystemFailure(operation: "inspect", code: EIO)
        }
    }

    private func plan(
        provider: HookConfigurationProvider,
        operation: HookConfigurationOperation,
        input: HookConfigurationInput,
        bridgeExecutablePath: String?
    ) throws -> HookConfigurationPlan {
        do {
            switch operation {
            case .connect:
                guard let bridgeExecutablePath else {
                    throw HookConfigurationApplicationError.invalidAtomicWrite
                }
                return try planner.planConnection(
                    provider: provider,
                    input: input,
                    bridgeExecutablePath: bridgeExecutablePath
                )
            case .disconnect:
                return try planner.planDisconnection(provider: provider, input: input)
            }
        } catch let error as HookConfigurationApplicationError {
            throw error
        } catch let error as HookConfigurationError {
            throw HookConfigurationApplicationError.planning(error)
        } catch {
            throw HookConfigurationApplicationError.planning(.serializationFailed)
        }
    }
}
