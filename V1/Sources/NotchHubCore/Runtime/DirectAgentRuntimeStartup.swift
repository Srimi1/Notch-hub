extension DirectAgentRuntime {
    func performStart(refreshLiveData: Bool) async {
        if persistenceState == .notLoaded {
            await loadCachedSnapshots()
        }
        _ = await discoverProviders()
        if refreshLiveData {
            let discoveredProviders = ProviderID.allCases.filter { executables[$0] != nil }
            await refreshProviders(discoveredProviders)
        }
    }

    func loadCachedSnapshots() async {
        do {
            let snapshots = try await snapshotStore.load()
            persistenceState = .available
            for (provider, snapshot) in snapshots {
                await applyCachedSnapshot(snapshot, keyedBy: provider)
            }
        } catch {
            persistenceState = .failed
            await record(
                severity: .error,
                code: "cache-load-failed",
                summary: "Encrypted usage cache could not be loaded."
            )
        }
    }

    func applyCachedSnapshot(_ snapshot: UsageSnapshot, keyedBy provider: ProviderID) async {
        guard snapshot.provider == provider else {
            let error = ProviderError.invalidPayload(provider: provider, field: "cached snapshot provider")
            await record(error, operation: "cache-load")
            return
        }

        lastGoodSnapshots[provider] = snapshot
        states[provider] = ProviderRuntimeState(
            provider: provider,
            connectionState: .stale(lastSuccessfulRefresh: snapshot.capturedAt, reason: nil),
            usageSnapshot: snapshot,
            snapshotSource: .encryptedCache,
            executableSource: states[provider]?.executableSource
        )
    }

    func discoverProvider(_ provider: ProviderID) async {
        let result = await Self.performDiscovery(provider, using: discovery)
        await applyDiscoveryResult(result, provider: provider)
    }

    nonisolated static func performDiscovery(
        _ provider: ProviderID,
        using discovery: any DirectAgentExecutableDiscovering
    ) async -> DiscoveryResult {
        do {
            return .resolved(try discovery.discover(provider))
        } catch {
            return .failed(ProviderError.wrapping(error, provider: provider))
        }
    }

    func applyDiscoveryResult(_ result: DiscoveryResult, provider: ProviderID) async {
        switch result {
        case let .resolved(executable):
            guard let executable else {
                executables[provider] = nil
                setConnectionState(
                    .notDetected,
                    for: provider,
                    executableSource: nil,
                    preserveExecutableSource: false
                )
                await record(.cliNotFound(provider: provider), operation: "discovery", severity: .info)
                return
            }
            guard executable.provider == provider else {
                executables[provider] = nil
                let error = ProviderError.invalidPayload(
                    provider: provider,
                    field: "discovered executable provider"
                )
                await applyFailure(error, provider: provider, operation: "discovery")
                return
            }
            executables[provider] = executable
            setConnectionState(connectionAfterDiscovery(provider), for: provider, executableSource: executable.source)
        case let .failed(providerError):
            executables[provider] = nil
            await applyFailure(providerError, provider: provider, operation: "discovery")
        }
    }

    func connectionAfterDiscovery(_ provider: ProviderID) -> ProviderConnectionState {
        guard let state = states[provider], let snapshot = state.usageSnapshot else {
            return .detected
        }
        let liveSnapshotIsFresh = state.snapshotSource == .liveProvider
            && !snapshot.isStale(at: now(), after: staleAfter)
        if liveSnapshotIsFresh {
            return .connected(lastRefresh: snapshot.capturedAt)
        }
        return .stale(lastSuccessfulRefresh: snapshot.capturedAt, reason: nil)
    }
}
