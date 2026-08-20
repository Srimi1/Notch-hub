import Combine
@preconcurrency import EventKit
import Foundation

/// Upcoming calendar events via EventKit. Requests read access on first use
/// (the prompt text comes from `NSCalendarsUsageDescription` in Info.plist) and
/// publishes the next handful of events for today and tomorrow.
@MainActor
final class CalendarService: ObservableObject {

    struct Event: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendarColorHex: String?
        let location: String?
        let url: URL?
    }

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [Event] = []
    @Published private(set) var lastError: String?

    private let store = EKEventStore()
    private var timer: Timer?
    private var eventStoreObserver: NSObjectProtocol?
    private var lastKnownStatus: EKAuthorizationStatus?

    func start() {
        refreshAuthorization()
        guard timer == nil else { return }
        // Refresh on a slow cadence; EventKit also posts change notifications.
        // The tick re-reads the authorization status first so access granted in
        // System Settings is picked up without relaunching the app.
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAuthorization()
                self?.reload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
            self.eventStoreObserver = nil
        }
    }

    var nextEvent: Event? {
        let now = Date()
        return events.first { $0.end > now && !$0.isAllDay }
    }

    /// Re-reads the live EventKit authorization status and reacts to a change.
    ///
    /// macOS does not notify an app when the user flips its Calendar switch in
    /// System Settings, so this is polled (on the refresh tick and whenever the
    /// app is activated). Without it, granting access required relaunching.
    func refreshAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status != lastKnownStatus else { return }
        lastKnownStatus = status

        switch EventKitAccessDecision.decide(for: status) {
        case .granted:
            access = .granted
            lastError = nil
            reload()
        case .denied:
            access = .denied
            events = []
            report(CalendarServiceError.accessDenied.localizedDescription)
        case .needsPrompt:
            access = .unknown
            requestAccess()
        }
    }

    private func requestAccess() {
        let handler: @Sendable (Bool, Error?) -> Void = { [weak self] granted, error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleAccessResult(granted: granted, errorMessage: errorMessage)
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, error in handler(granted, error) }
        } else {
            store.requestAccess(to: .event) { granted, error in handler(granted, error) }
        }
    }

    private func reload() {
        guard access == .granted else { return }
        let calendar = Calendar.current
        let start = Date()
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: start)) else {
            report(CalendarServiceError.invalidDateRange)
            return
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let mapped = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { ek in
                Event(
                    id: ek.eventIdentifier ?? "\(ek.startDate.timeIntervalSince1970).\(ek.title ?? "")",
                    title: DisplaySanitizer.text(ek.title, limit: 120).isEmpty
                        ? "Untitled event"
                        : DisplaySanitizer.text(ek.title, limit: 120),
                    start: ek.startDate,
                    end: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarColorHex: ek.calendar?.color?.hexString,
                    location: DisplaySanitizer.text(ek.structuredLocation?.title ?? ek.location, limit: 300),
                    url: ek.url
                )
            }
        let result = Array(mapped)
        events = result
        lastError = nil
    }

    private func handleAccessResult(granted: Bool, errorMessage: String?) {
        if let errorMessage {
            report(errorMessage)
            access = .denied
            return
        }
        access = granted ? .granted : .denied
        if granted {
            lastError = nil
            reload()
        } else {
            report(CalendarServiceError.accessDenied.localizedDescription)
        }
    }

    private func report(_ error: Error) {
        report(error.localizedDescription)
    }

    private func report(_ message: String) {
        lastError = message
        NSLog("NotchHub calendar: %@", message)
    }
}

private enum CalendarServiceError: LocalizedError {
    case accessDenied
    case invalidDateRange

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Calendar access is disabled in System Settings."
        case .invalidDateRange: "NotchHub could not calculate the calendar date range."
        }
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
