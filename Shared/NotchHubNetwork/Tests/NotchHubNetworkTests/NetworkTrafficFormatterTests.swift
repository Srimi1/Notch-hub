import Foundation
import Testing
@testable import NotchHubNetwork

@Suite("Network traffic formatter")
struct NetworkTrafficFormatterTests {
    private let english = Locale(identifier: "en_US")

    @Test("Small nonzero traffic never looks like zero")
    func smallValues() {
        #expect(NetworkTrafficUnit.megabitsPerSecond.format(mbps: 0.003, locale: english) == "<0.01")
        #expect(NetworkTrafficUnit.megabitsPerSecond.format(mbps: 0.04, locale: english) == "0.04")
        #expect(NetworkTrafficUnit.megabytesPerSecond.format(mbps: 0.03, locale: english) == "<0.01")
        #expect(NetworkTrafficUnit.megabytesPerSecond.format(mbps: 0.04, locale: english) == "0.01")
    }

    @Test("Units convert and identify themselves")
    func unitConversion() {
        #expect(NetworkTrafficUnit.megabitsPerSecond.label == "Mbps")
        #expect(NetworkTrafficUnit.megabytesPerSecond.label == "MB/s")
        #expect(NetworkTrafficUnit.megabytesPerSecond.format(mbps: 80, locale: english) == "10.0")
        #expect(NetworkTrafficFormatter.converted(mbps: 80, unit: .megabytesPerSecond) == 10)
    }

    @Test("Measured zero is distinct from unavailable")
    func zeroAndUnavailable() {
        #expect(NetworkTrafficUnit.megabitsPerSecond.format(mbps: 0, locale: english) == "0.00")
        #expect(NetworkTrafficFormatter.unavailable == "—")
    }

    @Test("The locale controls the decimal separator")
    func locale() {
        let german = Locale(identifier: "de_DE")
        #expect(NetworkTrafficUnit.megabitsPerSecond.format(mbps: 5.25, locale: german) == "5,25")
    }
}
