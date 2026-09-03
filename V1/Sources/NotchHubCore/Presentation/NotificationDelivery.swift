import Foundation
@preconcurrency import UserNotifications

public enum NotificationAuthorizationState: Sendable {
    case notDetermined
    case authorized
    case denied
}

public protocol NotificationDeliveryClient: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func deliver(_ notification: SmartQuietNotification) async throws
}

public enum NotificationProcessingResult: Equatable, Sendable {
    case none
    case delivered(Int)
    case unavailable
    case failed
}

public struct SystemNotificationDeliveryClient: NotificationDeliveryClient {
    public init() {}

    public func authorizationState() async -> NotificationAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(_ notification: SmartQuietNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Stateful delivery shell around the pure reducer. Authorization is queried
/// only after the reducer emits an actionable transition.
public actor SmartQuietNotificationController {
    private var state: SmartQuietPolicyState
    private let client: any NotificationDeliveryClient

    public init(
        state: SmartQuietPolicyState = .init(),
        client: any NotificationDeliveryClient = SystemNotificationDeliveryClient()
    ) {
        self.state = state
        self.client = client
    }

    public func observe(_ observation: SmartQuietObservation) async -> NotificationProcessingResult {
        let evaluation = SmartQuietNotificationPolicy.evaluate(state: state, observation: observation)
        state = evaluation.state
        guard !evaluation.notifications.isEmpty else { return .none }

        switch await client.authorizationState() {
        case .denied:
            return .unavailable
        case .notDetermined:
            do {
                guard try await client.requestAuthorization() else { return .unavailable }
            } catch {
                return .failed
            }
        case .authorized:
            break
        }

        do {
            for notification in evaluation.notifications {
                try await client.deliver(notification)
            }
            return .delivered(evaluation.notifications.count)
        } catch {
            return .failed
        }
    }
}
