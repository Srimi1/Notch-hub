extension DirectAgentRuntime {
    func refreshProviders(_ providers: [ProviderID]) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { [self] in
                    _ = await refresh(provider)
                }
            }
        }
    }

    func makeRefreshOperation(
        provider: ProviderID,
        executable: DiscoveredExecutable
    ) -> RefreshOperation {
        nextOperationID &+= 1
        let operationID = nextOperationID
        let adapterFactory = adapterFactory
        let refreshTimeout = refreshTimeout
        let task = Task {
            let adapter = try await adapterFactory.makeAdapter(
                for: provider,
                executable: executable,
                timeout: refreshTimeout
            )
            return try await adapter.fetchUsage()
        }
        return RefreshOperation(id: operationID, task: task)
    }

    func completeRefresh(
        _ operation: RefreshOperation,
        provider: ProviderID
    ) async -> ProviderRuntimeState {
        do {
            let snapshot = try await operation.task.value
            return await applyLiveSnapshot(snapshot, provider: provider, operationID: operation.id)
        } catch {
            let providerError = ProviderError.wrapping(error, provider: provider)
            if refreshOperations[provider]?.id == operation.id {
                refreshOperations[provider] = nil
                await applyFailure(providerError, provider: provider, operation: "refresh")
            }
            return resolvedState(for: provider)
        }
    }

    func applyLiveSnapshot(
        _ snapshot: UsageSnapshot,
        provider: ProviderID,
        operationID: UInt64
    ) async -> ProviderRuntimeState {
        guard snapshot.provider == provider else {
            let error = ProviderError.invalidPayload(provider: provider, field: "live snapshot provider")
            if refreshOperations[provider]?.id == operationID {
                refreshOperations[provider] = nil
                await applyFailure(error, provider: provider, operation: "refresh")
            }
            return resolvedState(for: provider)
        }
        guard refreshOperations[provider]?.id == operationID else {
            return resolvedState(for: provider)
        }

        refreshOperations[provider] = nil
        lastGoodSnapshots[provider] = snapshot
        states[provider] = ProviderRuntimeState(
            provider: provider,
            connectionState: .connected(lastRefresh: snapshot.capturedAt),
            usageSnapshot: snapshot,
            snapshotSource: .liveProvider,
            executableSource: executables[provider]?.source
        )
        await persistLastGoodSnapshots()
        return resolvedState(for: provider)
    }

    func persistLastGoodSnapshots() async {
        nextOperationID &+= 1
        let operationID = nextOperationID
        let previousTask = saveOperation?.task
        let snapshots = lastGoodSnapshots
        let snapshotStore = snapshotStore
        let task = Task<SaveResult, Never> {
            if let previousTask {
                _ = await previousTask.value
            }
            do {
                try await snapshotStore.save(snapshots)
                return .saved
            } catch {
                return .failed
            }
        }
        saveOperation = SaveOperation(id: operationID, task: task)
        let result = await task.value
        if saveOperation?.id == operationID {
            saveOperation = nil
            persistenceState = result == .saved ? .available : .failed
        }
        if result == .failed {
            await record(
                severity: .error,
                code: "cache-save-failed",
                summary: "Last-good usage snapshots could not be saved."
            )
        }
    }

    func applyFailure(
        _ error: ProviderError,
        provider: ProviderID,
        operation: String
    ) async {
        let resolvedConnection: ProviderConnectionState = if let snapshot = lastGoodSnapshots[provider] {
            .stale(lastSuccessfulRefresh: snapshot.capturedAt, reason: error)
        } else {
            connectionState(for: error)
        }
        setConnectionState(resolvedConnection, for: provider)
        await record(error, operation: operation)
    }

    func connectionState(for error: ProviderError) -> ProviderConnectionState {
        switch error {
        case .cliNotFound:
            .notDetected
        case .signedOut:
            .signedOut
        default:
            .failed(error)
        }
    }

    func setConnectionState(
        _ connectionState: ProviderConnectionState,
        for provider: ProviderID,
        executableSource: ExecutableSource? = nil,
        preserveExecutableSource: Bool = true
    ) {
        let previous = states[provider] ?? Self.initialState(for: provider)
        let resolvedExecutableSource = executableSource
            ?? (preserveExecutableSource ? previous.executableSource : nil)
        states[provider] = ProviderRuntimeState(
            provider: provider,
            connectionState: connectionState,
            usageSnapshot: previous.usageSnapshot,
            snapshotSource: previous.snapshotSource,
            executableSource: resolvedExecutableSource
        )
    }

    func resolvedState(for provider: ProviderID) -> ProviderRuntimeState {
        let state = states[provider] ?? Self.initialState(for: provider)
        guard case .connected = state.connectionState,
              let snapshot = state.usageSnapshot,
              snapshot.isStale(at: now(), after: staleAfter)
        else {
            return state
        }
        return ProviderRuntimeState(
            provider: provider,
            connectionState: .stale(lastSuccessfulRefresh: snapshot.capturedAt, reason: nil),
            usageSnapshot: snapshot,
            snapshotSource: state.snapshotSource,
            executableSource: state.executableSource
        )
    }
}
