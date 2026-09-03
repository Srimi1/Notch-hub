import Foundation
import Testing
@testable import NotchHubSafeFeatures

@MainActor
@Suite("Safe focus timer")
struct FocusTimerModelTests {
    @Test("Invalid initial duration falls back safely")
    func invalidInitialDuration() {
        let model = FocusTimerModel(minutes: 0)

        #expect(model.selectedMinutes == FocusTimerModel.defaultMinutes)
        #expect(model.remainingSeconds == FocusTimerModel.defaultMinutes * 60)
        #expect(model.lastIssue == .invalidDuration(validRange: FocusTimerModel.validMinuteRange))
    }

    @Test("Invalid changes preserve the current timer")
    func invalidDurationChange() {
        let model = FocusTimerModel(minutes: 15)

        #expect(!model.setDuration(minutes: 181))
        #expect(model.selectedMinutes == 15)
        #expect(model.remainingSeconds == 900)
        #expect(model.lastIssue == .invalidDuration(validRange: FocusTimerModel.validMinuteRange))
    }

    @Test("Running timer pauses with deterministic remaining time")
    func pausePreservesRemainingTime() {
        let start = Date(timeIntervalSince1970: 1000)
        let model = FocusTimerModel(minutes: 10)

        model.start(at: start)
        model.pause(at: start.addingTimeInterval(90))

        #expect(model.state == .paused)
        #expect(model.remainingSeconds == 510)
        #expect(model.clockLabel == "08:30")
        model.stopScheduling()
    }

    @Test("A session completes and counts exactly once")
    func completionIsOneTime() {
        let start = Date(timeIntervalSince1970: 1000)
        let model = FocusTimerModel(minutes: 1)

        model.start(at: start)
        model.refresh(at: start.addingTimeInterval(60))
        model.refresh(at: start.addingTimeInterval(120))

        #expect(model.state == .completed)
        #expect(model.remainingSeconds == 0)
        #expect(model.progress == 1)
        #expect(model.completedSessionCount == 1)
    }

    @Test("Running duration cannot be changed behind the user's back")
    func runningDurationIsLocked() {
        let model = FocusTimerModel(minutes: 25)
        model.start(at: Date(timeIntervalSince1970: 1000))

        #expect(!model.setDuration(minutes: 50))
        #expect(model.selectedMinutes == 25)
        #expect(model.state == .running)
        #expect(model.lastIssue == .durationLockedWhileRunning)
        model.stopScheduling()
    }

    @Test("Reset restores the selected duration")
    func resetRestoresDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        let model = FocusTimerModel(minutes: 15)
        model.start(at: start)
        model.pause(at: start.addingTimeInterval(120))

        model.reset()

        #expect(model.state == .idle)
        #expect(model.remainingSeconds == 900)
        #expect(model.progress == 0)
    }
}
