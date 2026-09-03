import Foundation
import Observation
import OSLog

public enum DashboardThermalState: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable

    public var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Warm"
        case .serious: "High"
        case .critical: "Critical"
        case .unavailable: "Unavailable"
        }
    }

    public var systemImage: String {
        switch self {
        case .nominal: "thermometer.low"
        case .fair: "thermometer.medium"
        case .serious, .critical: "thermometer.high"
        case .unavailable: "questionmark.circle"
        }
    }
}

public struct DashboardSnapshot: Sendable, Equatable {
    public let sampledAt: Date
    public let systemUptime: TimeInterval
    public let activeProcessorCount: Int
    public let physicalMemoryBytes: UInt64
    public let thermalState: DashboardThermalState
    public let isLowPowerModeEnabled: Bool

    public init(
        sampledAt: Date,
        systemUptime: TimeInterval,
        activeProcessorCount: Int,
        physicalMemoryBytes: UInt64,
        thermalState: DashboardThermalState,
        isLowPowerModeEnabled: Bool
    ) {
        self.sampledAt = sampledAt
        self.systemUptime = max(0, systemUptime)
        self.activeProcessorCount = max(0, activeProcessorCount)
        self.physicalMemoryBytes = physicalMemoryBytes
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

public struct DashboardUptime: Sendable, Equatable {
    public let days: Int
    public let hours: Int
    public let minutes: Int

    public init(days: Int, hours: Int, minutes: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }
}

@MainActor
public protocol DashboardSnapshotProviding {
    func snapshot(at date: Date) throws -> DashboardSnapshot
}

public struct ProcessDashboardSnapshotProvider: DashboardSnapshotProviding {
    public init() {}

    @MainActor
    public func snapshot(at date: Date) throws -> DashboardSnapshot {
        let processInfo = ProcessInfo.processInfo
        return DashboardSnapshot(
            sampledAt: date,
            systemUptime: processInfo.systemUptime,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            thermalState: Self.thermalState(from: processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }

    private static func thermalState(from state: ProcessInfo.ThermalState) -> DashboardThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }
}

@MainActor
@Observable
public final class DashboardModel {
    public private(set) var snapshot: DashboardSnapshot
    public private(set) var lastError: String?
    public private(set) var isRefreshing = false

    @ObservationIgnored private let provider: any DashboardSnapshotProviding
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var timer: Timer?

    private static let logger = Logger(subsystem: "com.notchhub.v1", category: "SafeDashboard")

    public init(
        provider: any DashboardSnapshotProviding = ProcessDashboardSnapshotProvider(),
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.provider = provider
        self.now = now
        self.snapshot = DashboardSnapshot(
            sampledAt: now(),
            systemUptime: 0,
            activeProcessorCount: 0,
            physicalMemoryBytes: 0,
            thermalState: .unavailable,
            isLowPowerModeEnabled: false
        )
        refresh()
    }

    public var uptimeComponents: DashboardUptime {
        let totalMinutes = max(0, Int(snapshot.systemUptime) / 60)
        return DashboardUptime(
            days: totalMinutes / 1440,
            hours: totalMinutes / 60 % 24,
            minutes: totalMinutes % 60
        )
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try provider.snapshot(at: now())
            lastError = nil
        } catch {
            lastError = "System summary is temporarily unavailable."
            Self.logger.error("Dashboard refresh failed: \(String(describing: error), privacy: .private(mask: .hash))")
        }
    }
}
