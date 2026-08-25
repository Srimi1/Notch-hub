import AppKit

/// Watches key presses delivered to NotchHub's own windows.
///
/// Local monitoring — unlike the global kind `PasteEventMonitor` uses — needs
/// no Accessibility grant, because the events are already the app's own. It
/// also gets to swallow them: returning nil from the handler stops the key from
/// reaching the view underneath, which is what lets the picker use plain digits
/// without them being typed into anything.
@MainActor
final class LocalKeyMonitor {

    /// Return true to consume the event.
    var onKeyDown: ((NSEvent) -> Bool)?

    private var monitor: Any?
    private let installMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    init(
        installMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = installMonitor { [weak self] event in
            guard let self, self.onKeyDown?(event) == true else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor { removeMonitor(monitor) }
        monitor = nil
    }
}
