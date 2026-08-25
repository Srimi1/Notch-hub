import AppKit
import Carbon.HIToolbox

/// A system-wide key combination.
///
/// `carbonModifiers` uses the Carbon mask constants (`cmdKey`, `shiftKey`, …)
/// rather than `NSEvent.ModifierFlags`, because that is what the hot-key API
/// takes and converting in one place is less error-prone than at every call.
struct HotKeySpec: Equatable, Sendable, Identifiable {
    let id: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// How the chord is written for a person: "⌘⇧Space".
    let label: String
}

/// Registers NotchHub's global shortcut with macOS.
///
/// Carbon's `RegisterEventHotKey` is used rather than an `NSEvent` global
/// monitor for two reasons that matter here: it needs no Accessibility grant,
/// so the shortcut works on a fresh install, and it *consumes* the chord, so
/// the app underneath never also receives it. The API is ancient but has no
/// modern replacement and is not deprecated.
@MainActor
final class HotKeyCenter {

    /// Called when the chord is pressed.
    var onHotKey: (() -> Void)?

    /// The chords offered in Settings.
    ///
    /// ⌘Space is deliberately absent: Spotlight owns it at a level no app can
    /// take, so offering it would just be a shortcut that never fires.
    nonisolated static let presets: [HotKeySpec] = [
        HotKeySpec(
            id: "cmd-shift-space",
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            label: "⌘⇧Space"
        ),
        HotKeySpec(
            id: "ctrl-opt-v",
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(controlKey | optionKey),
            label: "⌃⌥V"
        ),
        HotKeySpec(
            id: "cmd-shift-v",
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            label: "⌘⇧V"
        )
    ]

    nonisolated static var defaultSpec: HotKeySpec { presets[0] }

    nonisolated static func spec(id: String) -> HotKeySpec? {
        presets.first { $0.id == id }
    }

    /// What actually talks to Carbon. Injected so the registration lifecycle can
    /// be tested without touching the real event system.
    @MainActor
    struct Registrar {
        /// Registers the chord and returns an opaque token, or nil on failure.
        var register: (HotKeySpec, @escaping () -> Void) -> Any?
        var unregister: (Any) -> Void

        static let live = Registrar(
            register: { spec, handler in CarbonHotKey(spec: spec, handler: handler) },
            unregister: { token in (token as? CarbonHotKey)?.invalidate() }
        )
    }

    private(set) var spec: HotKeySpec
    private var token: Any?
    private let registrar: Registrar
    /// Set when macOS refused the chord — almost always because another app
    /// already owns it. Surfaced so the shortcut never fails silently.
    private(set) var lastRegistrationFailed = false

    /// Both parameters resolve inside the body rather than as default argument
    /// expressions: those are evaluated in a nonisolated context, which the
    /// main-actor `presets` and `Registrar.live` cannot be read from.
    init(spec: HotKeySpec? = nil, registrar: Registrar? = nil) {
        self.spec = spec ?? Self.defaultSpec
        self.registrar = registrar ?? .live
    }

    var isRegistered: Bool { token != nil }

    func start() {
        guard token == nil else { return }
        token = registrar.register(spec) { [weak self] in
            self?.onHotKey?()
        }
        lastRegistrationFailed = token == nil
        if lastRegistrationFailed {
            NSLog("NotchHub: could not register the \(spec.label) shortcut — another app may own it.")
        }
    }

    func stop() {
        if let token { registrar.unregister(token) }
        token = nil
    }

    /// Swap the chord, releasing the old one first so the two never both fire.
    func setSpec(_ newSpec: HotKeySpec) {
        guard newSpec != spec else { return }
        let wasRegistered = isRegistered
        stop()
        spec = newSpec
        if wasRegistered { start() }
    }
}

/// One live Carbon hot-key registration.
///
/// The Carbon handler is a C function pointer with no context beyond the
/// hot-key id, so registrations are looked up in a table keyed by that id.
@MainActor
final class CarbonHotKey {

    private static var nextID: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init?(spec: HotKeySpec, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1
        self.id = id

        // 'NHUB' — the signature only has to be unique within the process.
        let hotKeyID = EventHotKeyID(signature: 0x4E48_5542, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }
        hotKeyRef = ref
        Self.handlers[id] = handler
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.handlers[self.id] = nil
    }

    deinit {
        // `deinit` is nonisolated; the Carbon call is thread-safe and the table
        // cleanup is hopped to the main actor where it is isolated.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        let id = self.id
        Task { @MainActor in CarbonHotKey.handlers[id] = nil }
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // The Carbon handler runs on the main thread, but the compiler
            // cannot know that, so hop explicitly.
            Task { @MainActor in CarbonHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
