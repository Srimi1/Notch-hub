import Testing
@testable import NotchHub

/// Which service changes are allowed to rebuild the activity set. The clock and
/// the system monitor drove a full rebuild on every 1–2s tick, which is what
/// this pins shut.
@Suite("Activity relevance")
struct ServiceHubActivityTests {

    @Test
    func theClockSystemMonitorAndClipboardDoNotDriveActivities() {
        #expect(!ServiceHub.ActivityRelevance.drivesActivities("time"))
        #expect(!ServiceHub.ActivityRelevance.drivesActivities("system"))
        #expect(!ServiceHub.ActivityRelevance.drivesActivities("clipboard"))
    }

    @Test
    func activitySourcesDoDriveActivities() {
        for service in ["battery", "media", "calendar", "focus", "timers", "reminders"] {
            #expect(ServiceHub.ActivityRelevance.drivesActivities(service))
        }
    }
}
