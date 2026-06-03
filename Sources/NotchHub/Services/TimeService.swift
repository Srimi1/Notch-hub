import Combine
import Foundation

/// Publishes the current time on a 1-second cadence. Used by the collapsed
/// live strip (clock) and any module that needs a steady tick.
///
/// The timer is created lazily on first `start()` and torn down on `stop()`
/// so a hidden/idle notch isn't waking the CPU every second for nothing.
final class TimeService: ObservableObject {

    @Published private(set) var now = Date()

    private var timer: Timer?
    private let timeFormatter: DateFormatter
    private let dateFormatter: DateFormatter

    init() {
        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm"
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
    }

    var clock: String { timeFormatter.string(from: now) }
    var meridiem: String {
        let f = DateFormatter(); f.dateFormat = "a"
        return f.string(from: now)
    }

    var dateLabel: String { dateFormatter.string(from: now) }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        // .common so the clock keeps ticking while the user scrolls/interacts.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        now = Date()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
