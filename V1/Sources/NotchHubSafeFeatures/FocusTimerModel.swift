import Foundation
import Observation
import OSLog

public enum FocusTimerState: String, Sendable, Equatable {
    case idle
    case running
    case paused
    case completed

    public var title: String {
        switch self {
        case .idle: "Ready"
        case .running: "Focusing"
        case .paused: "Paused"
        case .completed: "Complete"
        }
    }
}

public enum FocusTimerIssue: Sendable, Equatable, Identifiable {
    case invalidDuration(validRange: ClosedRange<Int>)
    case durationLockedWhileRunning

    public var id: String {
        switch self {
        case .invalidDuration: "invalid-duration"
        case .durationLockedWhileRunning: "duration-locked"
        }
    }

    public var message: String {
        switch self {
        case let .invalidDuration(range):
            "Choose a focus session from \(range.lowerBound) to \(range.upperBound) minutes."
        case .durationLockedWhileRunning:
            "Pause or reset the current session before changing its duration."
        }
    }
}

@MainActor
@Observable
public final class FocusTimerModel {
    public static let validMinuteRange = 1 ... 180
    public static let defaultMinutes = 25

    public private(set) var state: FocusTimerState = .idle
    public private(set) var selectedMinutes: Int
    public private(set) var remainingSeconds: Int
    public private(set) var completedSessionCount = 0
    public private(set) var lastIssue: FocusTimerIssue?

    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var deadline: Date?
    @ObservationIgnored private var timer: Timer?

    private static let logger = Logger(subsystem: "com.notchhub.v1", category: "SafeFocus")

    public init(
        minutes: Int = FocusTimerModel.defaultMinutes,
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        let validMinutes: Int
        if Self.validMinuteRange.contains(minutes) {
            validMinutes = minutes
            self.lastIssue = nil
        } else {
            validMinutes = Self.defaultMinutes
            self.lastIssue = .invalidDuration(validRange: Self.validMinuteRange)
            Self.logger.error("Rejected an invalid initial focus duration")
        }
        self.selectedMinutes = validMinutes
        self.remainingSeconds = validMinutes * 60
        self.now = now
    }

    public var progress: Double {
        let totalSeconds = selectedMinutes * 60
        guard totalSeconds > 0 else { return 0 }
        return min(max(1 - Double(remainingSeconds) / Double(totalSeconds), 0), 1)
    }

    public var clockLabel: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @discardableResult
    public func setDuration(minutes: Int) -> Bool {
        guard state != .running else {
            lastIssue = .durationLockedWhileRunning
            return false
        }
        guard Self.validMinuteRange.contains(minutes) else {
            lastIssue = .invalidDuration(validRange: Self.validMinuteRange)
            Self.logger.error("Rejected an invalid focus duration")
            return false
        }
        selectedMinutes = minutes
        remainingSeconds = minutes * 60
        deadline = nil
        state = .idle
        lastIssue = nil
        return true
    }

    public func start() {
        start(at: now())
    }

    public func pause() {
        pause(at: now())
    }

    public func reset() {
        invalidateTimer()
        deadline = nil
        remainingSeconds = selectedMinutes * 60
        state = .idle
        lastIssue = nil
    }

    public func refresh() {
        refresh(at: now())
    }

    public func stopScheduling() {
        invalidateTimer()
    }

    func start(at date: Date) {
        guard state != .running else { return }
        if state == .completed || remainingSeconds == 0 {
            remainingSeconds = selectedMinutes * 60
        }
        deadline = date.addingTimeInterval(TimeInterval(remainingSeconds))
        state = .running
        lastIssue = nil
        scheduleTimer()
    }

    func pause(at date: Date) {
        guard state == .running else { return }
        refresh(at: date)
        guard state == .running else { return }
        invalidateTimer()
        deadline = nil
        state = .paused
    }

    func refresh(at date: Date) {
        guard state == .running, let deadline else { return }
        let interval = deadline.timeIntervalSince(date)
        guard interval > 0 else {
            complete()
            return
        }
        remainingSeconds = Int(ceil(interval))
    }

    private func scheduleTimer() {
        invalidateTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func complete() {
        guard state == .running else { return }
        invalidateTimer()
        deadline = nil
        remainingSeconds = 0
        state = .completed
        completedSessionCount += 1
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }
}
