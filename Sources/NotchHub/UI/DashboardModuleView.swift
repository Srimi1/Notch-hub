import SwiftUI

// MARK: - Dashboard (glanceable real tiles)

/// The Dashboard module and the tile it is built from. Split out of
/// `ExpandedDashboardView` to keep that file under the 500-line lint cap;
/// nothing else moved with it.
struct DashboardModuleView: View {
    @ObservedObject var time: TimeService
    @ObservedObject var battery: BatteryService
    @ObservedObject var system: SystemMonitorService
    let batteryWarningPercent: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            StatTile(symbol: "clock", title: time.clock, subtitle: time.dateLabel)
                .contentTransition(.numericText())
            if battery.hasBattery {
                StatTile(
                    symbol: battery.symbol,
                    title: "\(battery.percent)%",
                    subtitle: batterySub
                ) {
                    BatteryGlyphView(
                        level: battery.level,
                        state: batteryState,
                        height: 13
                    )
                }
            }
            StatTile(symbol: "cpu", title: "\(Int(system.cpuUsage * 100))%", subtitle: "CPU")
                .contentTransition(.numericText())
            StatTile(symbol: "memorychip", title: "\(Int(system.memoryUsage * 100))%", subtitle: "RAM")
                .contentTransition(.numericText())
        }
        // `contentTransition` only animates inside an animated change, so the
        // ticking values need one driving them.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: time.clock)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: battery.percent)
    }

    private var batteryState: BatteryGlyphState {
        BatteryGlyphState.resolve(
            percent: battery.percent,
            isCharging: battery.isCharging,
            isCharged: battery.isCharged,
            isLowPowerMode: battery.isLowPowerMode,
            warningPercent: batteryWarningPercent
        )
    }

    private var batterySub: String {
        if battery.isCharging { return "Charging" }
        if let minutes = battery.minutesRemaining {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "Battery"
    }
}

struct StatTile<Icon: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    /// Overrides the SF Symbol when a tile needs a live drawing instead — the
    /// battery glyph is the only one so far.
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Sized here so the symbol-led convenience init stays a plain
            // `Image`; the battery glyph draws at an explicit size and ignores it.
            icon()
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .topLeading)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: NotchTheme.cardRadius).fill(Color.white.opacity(0.07)))
    }
}

extension StatTile where Icon == Image {
    /// The ordinary symbol-led tile.
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) {
            Image(systemName: symbol)
        }
    }
}
