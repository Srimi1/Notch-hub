import Combine
@preconcurrency import EventKit
import Foundation

/// Upcoming calendar events via EventKit. Access is requested only when the user
/// explicitly asks for it (the prompt text comes from
/// `NSCalendarsUsageDescription` in Info.plist); until then the service simply
/// reports `.unknown`. Once granted it publishes the next handful of events for
/// today and tomorrow.
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
    private let reader = CalendarEventReader()
    private var timer: Timer?
    private var eventStoreObserver: NSObjectProtocol?
    private var lastKnownStatus: EKAuthorizationStatus?
    /// Guards against overlapping off-main reads: a 60s tick or a change
    /// notification that lands while a read is in flight is skipped rather than
    /// stacked, since the in-flight read already publishes fresh data.
    private var reloadInFlight = false

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
            // Deliberately does NOT prompt. This runs on the refresh tick and on
            // every app activation, so prompting here meant macOS could raise a
            // Calendar dialog the user never asked for, at a moment they never
            // chose. The UI offers an explicit Enable Calendar action instead.
            access = .unknown
        }
    }

    /// Ask EventKit for access. Call this only from an explicit user action —
    /// see `refreshAuthorization`.
    func requestAccess() {
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
        guard access == .granted, !reloadInFlight else { return }
        let calendar = Calendar.current
        let start = Date()
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: start)) else {
            report(CalendarServiceError.invalidDateRange)
            return
        }

        reloadInFlight = true
        // The EventKit query is a synchronous database read that used to run on
        // the main actor and stall the notch's first open. Run it on the reader
        // actor and only assign the Sendable result back here on the main actor.
        Task { [weak self] in
            guard let self else { return }
            let events = await self.reader.fetch(start: start, end: end)
            self.events = events
            self.lastError = nil
            self.reloadInFlight = false
        }
    }

    /// Map one EventKit event to a display `Event`, dropping any with a nil date.
    ///
    /// `EKEvent.startDate`/`endDate` are `null_unspecified` in EventKit's
    /// headers, so Swift imports them as implicitly-unwrapped optionals.
    /// Subscribed .ics feeds, CalDAV accounts, and detached recurrence
    /// occurrences can carry a nil date, which would nil-trap the whole app.
    /// Bind them before use rather than trusting the IUO. Nonisolated so the
    /// reader actor can call it off the main actor.
    nonisolated static func map(_ ek: EKEvent) -> Event? {
        guard let startDate = ek.startDate as Date?,
              let endDate = ek.endDate as Date?
        else {
            return nil
        }
        let title = DisplaySanitizer.text(ek.title, limit: 120)
        return Event(
            id: ek.eventIdentifier ?? "\(startDate.timeIntervalSince1970).\(title)",
            title: title.isEmpty ? "Untitled event" : title,
            start: startDate,
            end: endDate,
            isAllDay: ek.isAllDay,
            calendarColorHex: ek.calendar?.color?.hexString,
            location: DisplaySanitizer.text(ek.structuredLocation?.title ?? ek.location, limit: 300),
            url: ek.url
        )
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

/// Reads EventKit off the main actor.
///
/// `EKEventStore.events(matching:)` is a synchronous database read; on the main
/// actor it stalled the notch's first open. This actor owns its own store —
/// EventKit authorization is process-global, so a second, read-only store sees
/// the same grant — and hands back already-`Sendable` `Event` values, so the
/// service only assigns the result.
private actor CalendarEventReader {
    private let store = EKEventStore()

    func fetch(start: Date, end: Date) -> [CalendarService.Event] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let mapped = store.events(matching: predicate)
            .compactMap(CalendarService.map)
            .sorted { $0.start < $1.start }
            .prefix(8)
        return Array(mapped)
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
            let red = Int((rgb.redComponent * 255).rounded())
            let green = Int((rgb.greenComponent * 255).rounded())
            let blue = Int((rgb.blueComponent * 255).rounded())
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
    }
#endif
