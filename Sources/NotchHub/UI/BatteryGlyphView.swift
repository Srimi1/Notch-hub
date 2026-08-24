import SwiftUI

/// Which story the battery is telling right now.
///
/// Mirrors the colour language macOS and iOS already use, so the glyph reads
/// without a legend: green while power is connected, red when the charge is low
/// enough to act on, yellow in Low Power Mode, plain otherwise.
enum BatteryGlyphState: Equatable {
    case charged
    case charging
    case low
    case lowPower
    case normal

    /// Resolution is ordered, not additive: a battery can be several of these at
    /// once (low *and* charging *and* in Low Power Mode) and the user only needs
    /// the most actionable one. Plugged in beats low, because it is already
    /// being fixed.
    static func resolve(
        percent: Int,
        isCharging: Bool,
        isCharged: Bool,
        isLowPowerMode: Bool,
        warningPercent: Int
    ) -> BatteryGlyphState {
        if isCharged { return .charged }
        if isCharging { return .charging }
        // Keyed to the same threshold the Next Up battery warning uses, so the
        // glyph turns red exactly when the app decides the charge is worth
        // mentioning — not at a second, hardcoded number.
        if percent <= warningPercent { return .low }
        if isLowPowerMode { return .lowPower }
        return .normal
    }

    var tint: Color {
        switch self {
        case .charged, .charging: .green
        case .low: .red
        case .lowPower: .yellow
        case .normal: .white
        }
    }

    /// Only the low state animates on its own. Charging gets a one-shot bolt
    /// bounce instead, and the rest are static — a permanently animating menu
    /// bar is a distraction, not a feature.
    var pulses: Bool { self == .low }

    var showsBolt: Bool { self == .charging || self == .charged }
}

/// A battery drawn rather than picked from SF Symbols, so the fill can track the
/// real charge continuously instead of snapping between five symbol variants.
struct BatteryGlyphView: View {
    let level: Double
    let state: BatteryGlyphState
    var height: CGFloat = 11

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { height * 2 }
    private var cornerRadius: CGFloat { height * 0.3 }

    var body: some View {
        HStack(spacing: height * 0.09) {
            shell
            terminal
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: level)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
        .accessibilityElement()
        .accessibilityLabel("Battery")
        .accessibilityValue(accessibilityValue)
    }

    private var shell: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.55), lineWidth: max(1, height * 0.09))
            fill
            if state.showsBolt {
                Image(systemName: "bolt.fill")
                    .font(.system(size: height * 0.62, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private var fill: some View {
        let bar = RoundedRectangle(cornerRadius: cornerRadius * 0.7)
            .fill(state.tint)
            .padding(max(1, height * 0.14))
            // A hairline of colour at 0% reads as "empty", where nothing at all
            // reads as "broken".
            .frame(width: max(height * 0.22, (width - height * 0.28) * clampedLevel), alignment: .leading)
            .frame(width: width, alignment: .leading)

        if state.pulses, !reduceMotion {
            // Breathing, not blinking: a slow fade that draws the eye on a
            // glance without ever demanding it.
            bar.phaseAnimator([1.0, 0.45]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 1.1)
            }
        } else {
            bar
        }
    }

    private var terminal: some View {
        RoundedRectangle(cornerRadius: height * 0.08)
            .fill(Color.white.opacity(0.55))
            .frame(width: height * 0.13, height: height * 0.36)
    }

    private var clampedLevel: Double { min(max(level, 0), 1) }

    private var accessibilityValue: String {
        let percent = Int((clampedLevel * 100).rounded())
        return switch state {
        case .charged: "\(percent) percent, fully charged"
        case .charging: "\(percent) percent, charging"
        case .low: "\(percent) percent, low"
        case .lowPower: "\(percent) percent, Low Power Mode"
        case .normal: "\(percent) percent"
        }
    }
}
