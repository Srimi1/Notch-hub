import Foundation
import Testing
@testable import NotchHub

/// These strings sit in the collapsed notch, where there is room for about a
/// dozen characters and no room to be wrong about a boundary.
@Suite("Relative time")
struct RelativeTimeTests {

    @Test
    func timerPadsAndRollsIntoHours() {
        #expect(RelativeTime.timer(0) == "00:00")
        #expect(RelativeTime.timer(59) == "00:59")
        #expect(RelativeTime.timer(60) == "01:00")
        #expect(RelativeTime.timer(3599) == "59:59")
        #expect(RelativeTime.timer(3600) == "1:00:00")
    }

    /// A finished timer reads 00:00, never a negative countdown.
    @Test
    func timerNeverGoesNegative() {
        #expect(RelativeTime.timer(-5) == "00:00")
    }

    /// Rounds up, so a timer with 30 seconds left never displays 00:29.
    @Test
    func timerRoundsUpPartialSeconds() {
        #expect(RelativeTime.timer(0.4) == "00:01")
        #expect(RelativeTime.timer(59.5) == "01:00")
    }

    /// Remaining time is truncated, not rounded, so each case gets a second of
    /// slack — otherwise the microseconds spent evaluating the call tip 20:00
    /// into "in 19m" and the test fails for no real reason.
    @Test
    func shortCountdownCollapsesToNowThenMinutesThenHours() {
        let now = Date()
        #expect(RelativeTime.short(to: now.addingTimeInterval(-10)) == "now")
        #expect(RelativeTime.short(to: now.addingTimeInterval(30)) == "in 1m")
        #expect(RelativeTime.short(to: now.addingTimeInterval(20 * 60 + 1)) == "in 20m")
        #expect(RelativeTime.short(to: now.addingTimeInterval(3 * 3600 + 1)) == "in 3h")
    }

    @Test
    func agoCrossesMinuteHourAndDayBoundaries() {
        let now = Date()
        #expect(RelativeTime.ago(now.addingTimeInterval(-30)) == "now")
        #expect(RelativeTime.ago(now.addingTimeInterval(-60)) == "1m ago")
        #expect(RelativeTime.ago(now.addingTimeInterval(-2 * 3600)) == "2h ago")
        #expect(RelativeTime.ago(now.addingTimeInterval(-26 * 3600)) == "1d ago")
    }

    /// The clock now follows the system's 12/24-hour setting rather than forcing
    /// a US format, so assert the shape instead of an exact string.
    @Test
    func clockRendersATimeAndNoDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let text = RelativeTime.clock(date)

        #expect(text.contains(":"))
        #expect(!text.isEmpty)
        // A date component would make this far longer than "10:13" or "10:13 AM".
        #expect(text.count <= 10)
    }
}
