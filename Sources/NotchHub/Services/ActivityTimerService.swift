import Foundation
import Observation
import UserNotifications

enum ActivityTimerStatus: String, Codable, Sendable {
    case running
    case paused
    case completed
}

struct ActivityTimerRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var duration: TimeInterval
    var status: ActivityTimerStatus
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    var completedAt: Date?

    func remaining(at date: Date) -> TimeInterval {
        switch status {
        case .running:
            max(0, endDate?.timeIntervalSince(date) ?? 0)
        case .paused:
            max(0, pausedRemaining ?? 0)
        case .completed:
            0
        }
    }
}

enum ActivityTimerError: LocalizedError {
    case invalidDuration
    case tooManyTimers
    case notificationsDenied
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration: "Choose a timer between 1 minute and 24 hours."
        case .tooManyTimers: "NotchHub supports up to eight active timers."
        case .notificationsDenied: "Timer notifications are disabled in System Settings."
        case .persistenceFailed: "The timer state could not be saved."
        }
    }
}

@MainActor
protocol TimerNotificationScheduling: AnyObject {
    func schedule(id: UUID, title: String, endDate: Date) async throws
    func cancel(id: UUID)
}

@MainActor
final class SystemTimerNotificationScheduler: TimerNotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func schedule(id: UUID, title: String, endDate: Date) async throws {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw ActivityTimerError.notificationsDenied }

        let content = UNMutableNotificationContent()
        content.title = "Timer complete"
        content.body = title
        content.sound = .default
        let interval = max(1, endDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: id),
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    func cancel(id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: id)])
    }

    private static func identifier(for id: UUID) -> String {
        "notchhub.timer.\(id.uuidString)"
    }
}

@MainActor
@Observable
final class ActivityTimerService {
    private enum Key {
        static let timers = "nextUp.timers.v1"
    }

    private(set) var timers: [ActivityTimerRecord]
    private(set) var lastError: String?
    private(set) var currentDate: Date

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications: TimerNotificationScheduling
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var notificationTasks:
        [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private(set) var isStarted = false
    @ObservationIgnored var onChange: (() -> Void)?

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            notifications: SystemTimerNotificationScheduler(),
            now: Date.init
        )
    }

    init(
        defaults: UserDefaults,
        notifications: TimerNotificationScheduling,
        now: @escaping () -> Date
    ) {
        self.defaults = defaults
        self.notifications = notifications
        self.now = now
        timers = Self.restore(from: defaults)
        currentDate = now()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        isStarted = false
    }

    @discardableResult
    func create(title: String, duration: TimeInterval) -> UUID? {
        guard 60 ... 86_400 ~= duration else {
            report(ActivityTimerError.invalidDuration)
            return nil
        }
        guard timers.count < 8 else {
            report(ActivityTimerError.tooManyTimers)
            return nil
        }

        let id = UUID()
        let cleanedTitle = sanitizedTitle(title)
        let endDate = now().addingTimeInterval(duration)
        timers.append(
            ActivityTimerRecord(
                id: id,
                title: cleanedTitle,
                duration: duration,
                status: .running,
                endDate: endDate,
                pausedRemaining: nil,
                completedAt: nil
            )
        )
        persistAndNotify()
        scheduleNotification(id: id, title: cleanedTitle, endDate: endDate)
        return id
    }

    func pause(id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }),
              timers[index].status == .running
        else { return }
        timers[index].pausedRemaining = timers[index].remaining(at: now())
        timers[index].endDate = nil
        timers[index].status = .paused
        notifications.cancel(id: id)
        persistAndNotify()
    }

    func resume(id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }),
              timers[index].status == .paused
        else { return }
        let remaining = max(1, timers[index].pausedRemaining ?? timers[index].duration)
        let endDate = now().addingTimeInterval(remaining)
        timers[index].endDate = endDate
        timers[index].pausedRemaining = nil
        timers[index].status = .running
        timers[index].completedAt = nil
        let title = timers[index].title
        persistAndNotify()
        scheduleNotification(id: id, title: title, endDate: endDate)
    }

    func cancel(id: UUID) {
        notifications.cancel(id: id)
        timers.removeAll { $0.id == id }
        persistAndNotify()
    }

    func dismiss(id: UUID) {
        guard timers.contains(where: { $0.id == id && $0.status == .completed }) else { return }
        cancel(id: id)
    }

    func clearError() {
        lastError = nil
    }

    func tick() {
        let date = now()
        currentDate = date
        var didComplete = false
        for index in timers.indices where timers[index].status == .running {
            guard let endDate = timers[index].endDate, endDate <= date else { continue }
            timers[index].status = .completed
            timers[index].completedAt = date
            timers[index].endDate = nil
            timers[index].pausedRemaining = nil
            didComplete = true
        }

        if didComplete {
            persistAndNotify()
        } else if !timers.isEmpty {
            onChange?()
        }
    }

    private func scheduleNotification(id: UUID, title: String, endDate: Date) {
        let previousTask = notificationTasks[id]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self, notifications] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            guard self.isCurrentSchedule(id: id, endDate: endDate) else {
                self.finishNotificationTask(id: id, token: token)
                return
            }
            do {
                try await notifications.schedule(id: id, title: title, endDate: endDate)
                if !self.isCurrentSchedule(id: id, endDate: endDate) {
                    notifications.cancel(id: id)
                }
            } catch {
                if self.isCurrentSchedule(id: id, endDate: endDate) {
                    self.report(error)
                }
            }
            self.finishNotificationTask(id: id, token: token)
        }
        notificationTasks[id] = (token, task)
    }

    private func isCurrentSchedule(id: UUID, endDate: Date) -> Bool {
        timers.contains { timer in
            timer.id == id && timer.status == .running && timer.endDate == endDate
        }
    }

    private func finishNotificationTask(id: UUID, token: UUID) {
        guard notificationTasks[id]?.token == token else { return }
        notificationTasks[id] = nil
    }

    private func persistAndNotify() {
        do {
            let data = try JSONEncoder().encode(timers)
            defaults.set(data, forKey: Key.timers)
        } catch {
            report(ActivityTimerError.persistenceFailed)
        }
        onChange?()
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        NSLog("NotchHub timer: %@", message)
        onChange?()
    }

    private func sanitizedTitle(_ title: String) -> String {
        let cleaned = DisplaySanitizer.text(title, limit: 60)
        return cleaned.isEmpty ? "Timer" : cleaned
    }

    private static func restore(from defaults: UserDefaults) -> [ActivityTimerRecord] {
        guard let data = defaults.data(forKey: Key.timers) else { return [] }
        do {
            return try JSONDecoder().decode([ActivityTimerRecord].self, from: data)
                .prefix(8)
                .map { $0 }
        } catch {
            NSLog("NotchHub timer: failed to restore timer state: %@", error.localizedDescription)
            return []
        }
    }
}
