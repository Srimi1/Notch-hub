// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation
import OSLog

public actor NetworkTrafficMonitor: NetworkTrafficMonitoring {
    private struct Baseline: Sendable {
        let counters: NetworkInterfaceCounters
        let instant: ContinuousClock.Instant
    }

    private let counterSource: any NetworkCounterSource
    private let pathSource: any NetworkPathSource
    private let timeSource: any NetworkTrafficTimeSource
    private let lifecycleSource: any NetworkTrafficLifecycleSource
    private let sampleInterval: Duration
    private let staleAfter: Duration
    private let calculator = NetworkThroughputCalculator()
    private let logger = Logger(subsystem: "com.srimi.NotchHub", category: "NetworkTraffic")

    private var baseline: Baseline?
    private var selectedInterface: NetworkPathSnapshot.Interface?
    private var bindingID: UUID?
    private var runID: UUID?
    private var isSleeping = false
    private var samplingID: UUID?
    private var pathID: UUID?
    private var expirationID: UUID?
    private var samplingTask: Task<Void, Never>?
    private var pathTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<NetworkTrafficSnapshot>.Continuation] = [:]
    private var latestSnapshot = NetworkTrafficSnapshot.paused

    public init(
        counterSource: any NetworkCounterSource = SystemNetworkCounterSource(),
        pathSource: any NetworkPathSource = SystemNetworkPathSource(),
        timeSource: any NetworkTrafficTimeSource = ContinuousNetworkTrafficTimeSource(),
        lifecycleSource: any NetworkTrafficLifecycleSource = WorkspaceNetworkTrafficLifecycleSource(),
        sampleInterval: Duration = .seconds(1),
        staleAfter: Duration = .seconds(3)
    ) {
        self.counterSource = counterSource
        self.pathSource = pathSource
        self.timeSource = timeSource
        self.lifecycleSource = lifecycleSource

        let intervalSeconds = min(1, max(
            NetworkThroughputCalculator.minimumIntervalSeconds,
            sampleInterval.networkTrafficSeconds
        ))
        self.sampleInterval = .seconds(intervalSeconds)
        self.staleAfter = .seconds(min(
            3,
            max(intervalSeconds * 2, staleAfter.networkTrafficSeconds)
        ))
    }
}

extension NetworkTrafficMonitor {
    public func updates() async -> AsyncStream<NetworkTrafficSnapshot> {
        let subscriberID = UUID()
        let pair = AsyncStream.makeStream(
            of: NetworkTrafficSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        subscribers[subscriberID] = pair.continuation
        pair.continuation.yield(latestSnapshot)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }
        return pair.stream
    }

    public func start() async {
        guard runID == nil else { return }
        let identifier = UUID()
        runID = identifier
        isSleeping = false
        selectedInterface = nil
        bindingID = nil
        baseline = nil
        publish(.measuring)
        scheduleExpiration(runID: identifier)
        startPathObservation(runID: identifier)
        startSampling(runID: identifier)
        startLifecycleObservation(runID: identifier)
    }

    public func stop() async {
        guard runID != nil else {
            publish(.paused)
            return
        }
        runID = nil
        isSleeping = false
        selectedInterface = nil
        bindingID = nil
        baseline = nil
        cancelTasks()
        publish(.paused)
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
    }
}

extension NetworkTrafficMonitor {
    private func startPathObservation(runID: UUID) {
        pathTask?.cancel()
        let identifier = UUID()
        pathID = identifier
        let source = pathSource
        pathTask = Task.detached { [weak self] in
            let stream = await source.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                await self?.receivePath(
                    snapshot,
                    runID: runID,
                    pathID: identifier
                )
            }
        }
    }

    private func startSampling(runID: UUID) {
        samplingTask?.cancel()
        let identifier = UUID()
        samplingID = identifier
        let interval = sampleInterval
        let time = timeSource
        samplingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.sample(runID: runID, samplingID: identifier)
                do {
                    try await time.sleep(for: interval)
                } catch is CancellationError {
                    break
                } catch {
                    await self?.samplingTimerFailed(
                        error,
                        runID: runID,
                        samplingID: identifier
                    )
                    break
                }
            }
        }
    }

    private func startLifecycleObservation(runID: UUID) {
        lifecycleTask?.cancel()
        let source = lifecycleSource
        lifecycleTask = Task.detached { [weak self] in
            let stream = await source.events()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.receiveLifecycle(event, runID: runID)
            }
        }
    }
}

extension NetworkTrafficMonitor {
    private func receivePath(
        _ path: NetworkPathSnapshot,
        runID: UUID,
        pathID: UUID
    ) {
        guard self.runID == runID, self.pathID == pathID, !isSleeping else { return }
        guard path.status == .satisfied else {
            selectedInterface = nil
            bindingID = nil
            baseline = nil
            cancelExpiration()
            let message = path.unsatisfiedReason ?? "No network connection"
            publish(unavailable(message: message))
            return
        }
        guard let interface = path.activeInterface else {
            selectedInterface = nil
            bindingID = nil
            baseline = nil
            cancelExpiration()
            publish(unavailable(message: "No supported network interface"))
            return
        }
        guard selectedInterface?.index != interface.index
            || selectedInterface?.name != interface.name else { return }

        selectedInterface = interface
        bindingID = UUID()
        baseline = nil
        logger.info(
            "Network traffic bound to \(interface.name, privacy: .public) (index \(interface.index))"
        )
        publish(measuring(interfaceName: interface.name))
        scheduleExpiration(runID: runID)
    }

    private func receiveLifecycle(_ event: NetworkTrafficLifecycleEvent, runID: UUID) {
        guard self.runID == runID else { return }
        switch event {
        case .willSleep:
            guard !isSleeping else { return }
            isSleeping = true
            selectedInterface = nil
            bindingID = nil
            baseline = nil
            cancelSamplingAndPathTasks()
            cancelExpiration()
            publish(unavailable(message: "Paused while the Mac sleeps"))
        case .didWake:
            guard isSleeping else { return }
            isSleeping = false
            publish(.measuring)
            scheduleExpiration(runID: runID)
            startPathObservation(runID: runID)
            startSampling(runID: runID)
        }
    }
}

extension NetworkTrafficMonitor {
    private func sample(runID: UUID, samplingID: UUID) async {
        guard self.runID == runID,
              self.samplingID == samplingID,
              !isSleeping,
              let interface = selectedInterface,
              let bindingID else { return }

        guard let current = await readCounters(
            interface: interface,
            bindingID: bindingID,
            runID: runID,
            samplingID: samplingID
        ) else { return }
        let now = await timeSource.now()
        guard samplingContextIsCurrent(
            runID: runID,
            samplingID: samplingID,
            bindingID: bindingID
        ) else { return }
        updateRate(
            current: current,
            at: now,
            interface: interface,
            runID: runID
        )
    }

    private func readCounters(
        interface: NetworkPathSnapshot.Interface,
        bindingID: UUID,
        runID: UUID,
        samplingID: UUID
    ) async -> NetworkInterfaceCounters? {
        let fetched: NetworkInterfaceCounters?
        do {
            fetched = try await counterSource.counters(forInterfaceIndex: interface.index)
        } catch is CancellationError {
            return nil
        } catch let sourceError as NetworkTrafficSourceError {
            guard samplingContextIsCurrent(
                runID: runID,
                samplingID: samplingID,
                bindingID: bindingID
            ) else { return nil }
            sourceFailed(sourceError, interface: interface)
            return nil
        } catch {
            guard samplingContextIsCurrent(
                runID: runID,
                samplingID: samplingID,
                bindingID: bindingID
            ) else { return nil }
            sourceFailed(.dependencyFailure(
                component: "counter source",
                description: String(describing: error)
            ), interface: interface)
            return nil
        }
        guard samplingContextIsCurrent(
            runID: runID,
            samplingID: samplingID,
            bindingID: bindingID
        ) else { return nil }
        guard let current = fetched else {
            self.bindingID = UUID()
            sourceFailed(.interfaceDisappeared(interface.index), interface: interface)
            return nil
        }
        return current
    }

    private func updateRate(
        current: NetworkInterfaceCounters,
        at now: ContinuousClock.Instant,
        interface: NetworkPathSnapshot.Interface,
        runID: UUID
    ) {
        guard let previous = baseline else {
            baseline = Baseline(counters: current, instant: now)
            publish(measuring(interfaceName: interface.name))
            scheduleExpiration(runID: runID)
            return
        }

        let elapsed = now.networkTrafficSeconds(since: previous.instant)
        switch calculator.evaluate(
            previous: previous.counters,
            current: current,
            elapsedSeconds: elapsed,
            maximumGapSeconds: staleAfter.networkTrafficSeconds
        ) {
        case .tooSoon:
            return
        case let .rebaseline(reason):
            logger.debug("Network traffic rebaseline: \(reason.rawValue, privacy: .public)")
            baseline = Baseline(counters: current, instant: now)
            publish(measuring(interfaceName: interface.name))
            scheduleExpiration(runID: runID)
        case let .rate(download, upload):
            baseline = Baseline(counters: current, instant: now)
            publish(NetworkTrafficSnapshot(
                downloadMbps: download,
                uploadMbps: upload,
                interfaceName: interface.name,
                state: .live
            ))
            scheduleExpiration(runID: runID)
        }
    }

    private func sourceFailed(
        _ error: NetworkTrafficSourceError,
        interface: NetworkPathSnapshot.Interface
    ) {
        baseline = nil
        cancelExpiration()
        publish(NetworkTrafficSnapshot(
            downloadMbps: 0,
            uploadMbps: 0,
            interfaceName: interface.name,
            state: .unavailable(message: error.userMessage),
            sourceError: error
        ))
    }

    private func samplingContextIsCurrent(
        runID: UUID,
        samplingID: UUID,
        bindingID: UUID
    ) -> Bool {
        self.runID == runID
            && self.samplingID == samplingID
            && self.bindingID == bindingID
            && !isSleeping
    }

    private func samplingTimerFailed(
        _ error: any Error,
        runID: UUID,
        samplingID: UUID
    ) {
        guard self.runID == runID, self.samplingID == samplingID else { return }
        baseline = nil
        self.samplingID = nil
        samplingTask = nil
        cancelExpiration()
        let sourceError = NetworkTrafficSourceError.dependencyFailure(
            component: "sampling timer",
            description: String(describing: error)
        )
        publish(NetworkTrafficSnapshot(
            downloadMbps: 0,
            uploadMbps: 0,
            interfaceName: selectedInterface?.name,
            state: .unavailable(message: sourceError.userMessage),
            sourceError: sourceError
        ))
    }
}

extension NetworkTrafficMonitor {
    private func scheduleExpiration(runID: UUID) {
        expirationTask?.cancel()
        let identifier = UUID()
        expirationID = identifier
        let delay = staleAfter
        let time = timeSource
        expirationTask = Task.detached { [weak self] in
            do {
                try await time.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                await self?.expirationTimerFailed(error, runID: runID, expirationID: identifier)
                return
            }
            await self?.expire(runID: runID, expirationID: identifier)
        }
    }

    private func expire(runID: UUID, expirationID: UUID) {
        guard self.runID == runID, self.expirationID == expirationID else { return }
        baseline = nil
        self.expirationID = nil
        expirationTask = nil
        publish(unavailable(
            message: selectedInterface == nil
                ? "No active network interface"
                : "Waiting for a fresh network reading",
            interfaceName: selectedInterface?.name
        ))
    }

    private func expirationTimerFailed(
        _ error: any Error,
        runID: UUID,
        expirationID: UUID
    ) {
        guard self.runID == runID, self.expirationID == expirationID else { return }
        let sourceError = NetworkTrafficSourceError.dependencyFailure(
            component: "freshness timer",
            description: String(describing: error)
        )
        publish(NetworkTrafficSnapshot(
            downloadMbps: 0,
            uploadMbps: 0,
            interfaceName: selectedInterface?.name,
            state: .unavailable(message: sourceError.userMessage),
            sourceError: sourceError
        ))
    }

    private func publish(_ snapshot: NetworkTrafficSnapshot) {
        guard snapshot != latestSnapshot else { return }
        logTransition(from: latestSnapshot, to: snapshot)
        latestSnapshot = snapshot
        for subscriber in subscribers.values {
            subscriber.yield(snapshot)
        }
    }

    private func logTransition(from previous: NetworkTrafficSnapshot, to current: NetworkTrafficSnapshot) {
        if let error = current.sourceError, error != previous.sourceError {
            logger.error("Network traffic source failure: \(error.localizedDescription, privacy: .public)")
        } else if previous.sourceError != nil, current.sourceError == nil {
            logger.info("Network traffic source recovered")
        }
    }

    private func measuring(interfaceName: String?) -> NetworkTrafficSnapshot {
        NetworkTrafficSnapshot(
            downloadMbps: 0,
            uploadMbps: 0,
            interfaceName: interfaceName,
            state: .measuring
        )
    }

    private func unavailable(message: String, interfaceName: String? = nil) -> NetworkTrafficSnapshot {
        NetworkTrafficSnapshot(
            downloadMbps: 0,
            uploadMbps: 0,
            interfaceName: interfaceName,
            state: .unavailable(message: message)
        )
    }

    private func cancelExpiration() {
        expirationID = nil
        expirationTask?.cancel()
        expirationTask = nil
    }

    private func cancelSamplingAndPathTasks() {
        samplingID = nil
        samplingTask?.cancel()
        samplingTask = nil
        pathID = nil
        pathTask?.cancel()
        pathTask = nil
    }

    private func cancelTasks() {
        cancelSamplingAndPathTasks()
        cancelExpiration()
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }
}
