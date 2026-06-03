import Combine
import EventKit
import Foundation

/// Upcoming calendar events via EventKit. Requests read access on first use
/// (the prompt text comes from `NSCalendarsUsageDescription` in Info.plist) and
/// publishes the next handful of events for today and tomorrow.
final class CalendarService: ObservableObject {

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendarColorHex: String?
    }

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [Event] = []

    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        requestAccess()
        guard timer == nil else { return }
        // Refresh on a slow cadence; EventKit also posts change notifications.
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .EKEventStoreChanged, object: store
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    var nextEvent: Event? {
        let now = Date()
        return events.first { $0.end > now && !$0.isAllDay }
    }

    private func requestAccess() {
        let handler: (Bool, Error?) -> Void = { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                if granted { self?.reload() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, error in handler(granted, error) }
        } else {
            store.requestAccess(to: .event) { granted, error in handler(granted, error) }
        }
    }

    @objc private func reload() {
        guard access == .granted else { return }
        let calendar = Calendar.current
        let start = Date()
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: start)) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let mapped = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { ek in
                Event(
                    id: ek.eventIdentifier ?? UUID().uuidString,
                    title: ek.title ?? "Untitled",
                    start: ek.startDate,
                    end: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarColorHex: ek.calendar?.color?.hexString
                )
            }
        let result = Array(mapped)
        DispatchQueue.main.async { self.events = result }
    }
}

#if canImport(AppKit)
    import AppKit
    extension NSColor {
        /// Hex like "#FF8800" for piping a calendar's tint into SwiftUI.
        var hexString: String? {
            guard let rgb = usingColorSpace(.sRGB) else { return nil }
            let r = Int((rgb.redComponent * 255).rounded())
            let g = Int((rgb.greenComponent * 255).rounded())
            let b = Int((rgb.blueComponent * 255).rounded())
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
#endif
