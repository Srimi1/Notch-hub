import Testing
@testable import NotchHubCore

@Suite("Notification delivery authorization")
struct NotificationDeliveryTests {
    @Test("No actionable transition avoids authorization entirely")
    func quietObservationDoesNotAskPermission() async {
        let client = RecordingNotificationClient(state: .notDetermined)
        let controller = SmartQuietNotificationController(client: client)

        let result = await controller.observe(.empty)
        let counts = await client.counts()

        #expect(result == .none)
        #expect(counts == .init(status: 0, requests: 0, deliveries: 0))
    }

    @Test("First actionable event asks contextually and then delivers")
    func actionableEventRequestsPermission() async {
        let client = RecordingNotificationClient(state: .notDetermined)
        let controller = SmartQuietNotificationController(client: client)
        _ = await controller.observe(.empty)

        let result = await controller.observe(approvalObservation)
        let counts = await client.counts()

        #expect(result == .delivered(1))
        #expect(counts == .init(status: 1, requests: 1, deliveries: 1))
    }

    @Test("Denied authorization remains quiet")
    func deniedAuthorizationDoesNotDeliver() async {
        let client = RecordingNotificationClient(state: .denied)
        let controller = SmartQuietNotificationController(client: client)
        _ = await controller.observe(.empty)

        let result = await controller.observe(approvalObservation)
        let counts = await client.counts()

        #expect(result == .unavailable)
        #expect(counts == .init(status: 1, requests: 0, deliveries: 0))
    }

    private var approvalObservation: SmartQuietObservation {
        .init(
            providers: [],
            sessions: [],
            approvals: [
                .init(id: "approval", provider: .codex, projectName: "NotchHub"),
            ]
        )
    }
}

private actor RecordingNotificationClient: NotificationDeliveryClient {
    struct Counts: Equatable, Sendable {
        let status: Int
        let requests: Int
        let deliveries: Int
    }

    private let state: NotificationAuthorizationState
    private var statusCount = 0
    private var requestCount = 0
    private var deliveryCount = 0

    init(state: NotificationAuthorizationState) {
        self.state = state
    }

    func authorizationState() -> NotificationAuthorizationState {
        statusCount += 1
        return state
    }

    func requestAuthorization() throws -> Bool {
        requestCount += 1
        return true
    }

    func deliver(_ notification: SmartQuietNotification) {
        deliveryCount += 1
    }

    func counts() -> Counts {
        Counts(status: statusCount, requests: requestCount, deliveries: deliveryCount)
    }
}
