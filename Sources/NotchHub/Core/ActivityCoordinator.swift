import Combine
import Foundation
import Observation

@MainActor
@Observable
final class ActivityCoordinator {
    private(set) var currentActivity: ActivitySnapshot?
    private(set) var queue: [ActivitySnapshot] = []

    @ObservationIgnored let activityDidChange = PassthroughSubject<Void, Never>()
    @ObservationIgnored private let preferences: ActivityPreferences
    @ObservationIgnored private let minimumDwell: TimeInterval
    @ObservationIgnored private var lastCandidates: [ActivitySnapshot] = []
    @ObservationIgnored private var lastSwitchDate: Date?

    init(preferences: ActivityPreferences, minimumDwell: TimeInterval = 4) {
        self.preferences = preferences
        self.minimumDwell = max(0, minimumDwell)
    }

    func submit(_ candidates: [ActivitySnapshot], now: Date = .now) {
        lastCandidates = candidates
        let ranked = Self.rank(
            candidates.filter { preferences.isEnabled($0.kind) },
            mediaPinned: !preferences.urgentOverridesMedia
        )
        let nextCurrent = selectCurrent(from: ranked, now: now)
        let nextQueue = Self.queue(current: nextCurrent, ranked: ranked)

        guard nextCurrent != currentActivity || nextQueue != queue else { return }
        if nextCurrent?.id != currentActivity?.id {
            lastSwitchDate = nextCurrent == nil ? nil : now
        }
        currentActivity = nextCurrent
        queue = nextQueue
        activityDidChange.send()
    }

    func refreshForPreferences(now: Date = .now) {
        submit(lastCandidates, now: now)
    }

    private func selectCurrent(from ranked: [ActivitySnapshot], now: Date) -> ActivitySnapshot? {
        guard let top = ranked.first else { return nil }
        guard let currentActivity,
              let refreshedCurrent = ranked.first(where: { $0.id == currentActivity.id })
        else {
            return top
        }

        if top.id == refreshedCurrent.id {
            return top
        }
        let topPriority = Self.effectivePriority(
            for: top,
            mediaPinned: !preferences.urgentOverridesMedia
        )
        let currentPriority = Self.effectivePriority(
            for: refreshedCurrent,
            mediaPinned: !preferences.urgentOverridesMedia
        )
        if topPriority > currentPriority {
            return top
        }

        let dwellElapsed = lastSwitchDate.map { now.timeIntervalSince($0) >= minimumDwell } ?? true
        return dwellElapsed ? top : refreshedCurrent
    }

    private static func rank(
        _ candidates: [ActivitySnapshot],
        mediaPinned: Bool
    ) -> [ActivitySnapshot] {
        candidates.sorted { lhs, rhs in
            let lhsPriority = effectivePriority(for: lhs, mediaPinned: mediaPinned)
            let rhsPriority = effectivePriority(for: rhs, mediaPinned: mediaPinned)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            let lhsDate = lhs.relevanceDate ?? .distantFuture
            let rhsDate = rhs.relevanceDate ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.id < rhs.id
        }
    }

    private static func effectivePriority(
        for activity: ActivitySnapshot,
        mediaPinned: Bool
    ) -> Int {
        mediaPinned && activity.kind == .media ? Int.max : activity.priority.rawValue
    }

    private static func queue(
        current: ActivitySnapshot?,
        ranked: [ActivitySnapshot]
    ) -> [ActivitySnapshot] {
        guard let current else { return [] }
        let remaining = ranked.filter { $0.id != current.id }
        return Array(([current] + remaining).prefix(5))
    }
}
