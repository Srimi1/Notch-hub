import Testing
@testable import NotchHub

/// A battery is often several things at once — low, charging, and in Low Power
/// Mode together — but the glyph shows one colour. These pin which one wins.
@Suite("Battery glyph state")
struct BatteryGlyphStateTests {

    private func state(
        percent: Int,
        charging: Bool = false,
        charged: Bool = false,
        lowPower: Bool = false,
        warning: Int = 20
    ) -> BatteryGlyphState {
        BatteryGlyphState.resolve(
            percent: percent,
            isCharging: charging,
            isCharged: charged,
            isLowPowerMode: lowPower,
            warningPercent: warning
        )
    }

    @Test
    func plainDischargeAboveTheThresholdIsUnremarkable() {
        #expect(state(percent: 80) == .normal)
        #expect(state(percent: 21) == .normal)
    }

    /// The boundary is inclusive, matching the Next Up battery warning that uses
    /// the same number.
    @Test
    func theWarningThresholdItselfCountsAsLow() {
        #expect(state(percent: 20) == .low)
        #expect(state(percent: 19) == .low)
        #expect(state(percent: 0) == .low)
    }

    @Test
    func theThresholdFollowsTheUsersSetting() {
        #expect(state(percent: 30, warning: 20) == .normal)
        #expect(state(percent: 30, warning: 35) == .low)
        #expect(state(percent: 10, warning: 5) == .normal)
    }

    /// Being plugged in is the answer to being low, so it outranks it — a red
    /// pulsing battery while charging would be telling the user to do something
    /// they have already done.
    @Test
    func chargingOutranksLow() {
        #expect(state(percent: 5, charging: true) == .charging)
        #expect(state(percent: 5, charging: true, lowPower: true) == .charging)
    }

    @Test
    func fullyChargedOutranksCharging() {
        #expect(state(percent: 100, charging: true, charged: true) == .charged)
    }

    /// Low Power Mode is the weakest signal: it only shows when there is nothing
    /// more pressing to report.
    @Test
    func lowPowerModeOnlyShowsWhenNothingElseDoes() {
        #expect(state(percent: 50, lowPower: true) == .lowPower)
        #expect(state(percent: 15, lowPower: true) == .low)
        #expect(state(percent: 50, charging: true, lowPower: true) == .charging)
    }

    /// Only the low state animates unprompted — everything else would be motion
    /// in the menu bar for no reason.
    @Test
    func onlyLowPulsesAndOnlyPoweredStatesShowABolt() {
        #expect(state(percent: 10).pulses)
        #expect(!state(percent: 50).pulses)
        #expect(!state(percent: 50, charging: true).pulses)
        #expect(!state(percent: 50, lowPower: true).pulses)

        #expect(state(percent: 50, charging: true).showsBolt)
        #expect(state(percent: 100, charged: true).showsBolt)
        #expect(!state(percent: 10).showsBolt)
        #expect(!state(percent: 50).showsBolt)
    }
}
