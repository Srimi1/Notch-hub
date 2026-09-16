// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation

public enum NetworkTrafficUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case megabitsPerSecond = "Mbps"
    case megabytesPerSecond = "MB/s"

    public var id: String { rawValue }
    public var label: String { rawValue }

    public func format(mbps: Double, locale: Locale = .current) -> String {
        NetworkTrafficFormatter.format(mbps: mbps, unit: self, locale: locale)
    }
}

public enum NetworkTrafficFormatter {
    public static let unavailable = "—"

    /// Formats the numeric portion of a rate. The caller can show `unit.label` beside it.
    /// Small nonzero values use a less-than value instead of rounding to a misleading zero.
    public static func format(
        mbps: Double,
        unit: NetworkTrafficUnit = .megabitsPerSecond,
        locale: Locale = .current
    ) -> String {
        let value = converted(mbps: mbps, unit: unit)
        let formatter = numberFormatter(locale: locale)

        guard value.isFinite, value > 0 else {
            return fixed(0, digits: 2, formatter: formatter)
        }
        guard value >= 0.005 else {
            return "<" + fixed(0.01, digits: 2, formatter: formatter)
        }
        if value < 10, rounded(value, digits: 2) < 10 {
            return fixed(value, digits: 2, formatter: formatter)
        }
        if value < 100, rounded(value, digits: 1) < 100 {
            return fixed(value, digits: 1, formatter: formatter)
        }
        return fixed(value, digits: 0, formatter: formatter)
    }

    public static func converted(mbps: Double, unit: NetworkTrafficUnit) -> Double {
        switch unit {
        case .megabitsPerSecond:
            mbps
        case .megabytesPerSecond:
            mbps / 8
        }
    }

    private static func numberFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.roundingMode = .halfUp
        return formatter
    }

    private static func fixed(
        _ value: Double,
        digits: Int,
        formatter: NumberFormatter
    ) -> String {
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private static func rounded(_ value: Double, digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}
