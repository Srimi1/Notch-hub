import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import NotchHub

/// The shortcut is the only way into the clipboard picker from another app, so
/// registration has to be exact: one live chord at a time, released before a
/// replacement is taken.
@Suite("Clipboard shortcut")
@MainActor
struct HotKeyTests {

    private final class Log: @unchecked Sendable {
        var registered: [HotKeySpec] = []
        var unregistered = 0
        var handler: (() -> Void)?
    }

    private func makeCenter(
        log: Log,
        succeeds: Bool = true,
        spec: HotKeySpec? = nil
    ) -> HotKeyCenter {
        let registrar = HotKeyCenter.Registrar(
            register: { spec, handler in
                guard succeeds else { return nil }
                log.registered.append(spec)
                log.handler = handler
                return "token-\(log.registered.count)"
            },
            unregister: { _ in log.unregistered += 1 }
        )
        return HotKeyCenter(spec: spec, registrar: registrar)
    }

    /// ⌘⇧Space by default — and ⌘Space is deliberately not on the menu, since
    /// Spotlight owns it at a level no app can take.
    @Test
    func theDefaultChordAvoidsSpotlight() {
        #expect(HotKeyCenter.defaultSpec.label == "⌘⇧Space")
        let cmdOnly = UInt32(cmdKey)
        for preset in HotKeyCenter.presets {
            #expect(preset.carbonModifiers != cmdOnly)
        }
        #expect(Set(HotKeyCenter.presets.map(\.id)).count == HotKeyCenter.presets.count)
    }

    /// Starting registers exactly once, however many times it is called.
    @Test
    func startingRegistersOnce() {
        let log = Log()
        let center = makeCenter(log: log)

        center.start()
        center.start()

        #expect(log.registered.count == 1)
        #expect(center.isRegistered)
        #expect(center.lastRegistrationFailed == false)
    }

    /// A chord another app already owns must be reported, not swallowed.
    @Test
    func aRefusedRegistrationIsRecorded() {
        let log = Log()
        let center = makeCenter(log: log, succeeds: false)

        center.start()

        #expect(center.isRegistered == false)
        #expect(center.lastRegistrationFailed)
    }

    /// Changing the chord releases the old one first, so two never fire.
    @Test
    func changingTheChordReleasesThePreviousOne() {
        let log = Log()
        let center = makeCenter(log: log)
        center.start()

        center.setSpec(HotKeyCenter.presets[1])

        #expect(log.unregistered == 1)
        #expect(log.registered.count == 2)
        #expect(log.registered.last == HotKeyCenter.presets[1])
        #expect(center.spec == HotKeyCenter.presets[1])
    }

    /// Setting the chord it already has is a no-op — re-registering would drop
    /// the shortcut for an instant for no reason.
    @Test
    func settingTheSameChordChangesNothing() {
        let log = Log()
        let center = makeCenter(log: log)
        center.start()

        center.setSpec(HotKeyCenter.defaultSpec)

        #expect(log.registered.count == 1)
        #expect(log.unregistered == 0)
    }

    /// A chord swapped while the shortcut is off stays off.
    @Test
    func changingTheChordWhileStoppedDoesNotRegister() {
        let log = Log()
        let center = makeCenter(log: log)

        center.setSpec(HotKeyCenter.presets[2])

        #expect(log.registered.isEmpty)
        #expect(center.isRegistered == false)
    }

    /// Stopping releases the registration.
    @Test
    func stoppingUnregisters() {
        let log = Log()
        let center = makeCenter(log: log)
        center.start()

        center.stop()

        #expect(log.unregistered == 1)
        #expect(center.isRegistered == false)
    }

    /// The press reaches the app.
    @Test
    func pressingTheChordCallsBack() {
        let log = Log()
        let center = makeCenter(log: log)
        var fired = 0
        center.onHotKey = { fired += 1 }
        center.start()

        log.handler?()

        #expect(fired == 1)
    }

    /// The stored preference survives a relaunch and falls back safely if the
    /// saved id no longer names a preset.
    @Test
    func thePreferenceRoundTripsAndFallsBack() {
        let suite = "notchhub.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let preferences = HotKeyPreferences(defaults: defaults)

        #expect(preferences.clipPickerEnabled)
        #expect(preferences.clipPickerSpec == HotKeyCenter.defaultSpec)

        preferences.clipPickerSpecID = HotKeyCenter.presets[1].id
        #expect(HotKeyPreferences(defaults: defaults).clipPickerSpec == HotKeyCenter.presets[1])

        preferences.clipPickerSpecID = "a-preset-that-was-removed"
        #expect(preferences.clipPickerSpec == HotKeyCenter.defaultSpec)
    }
}

/// The picker is meant to be driven without the pointer, so the key mapping is
/// worth pinning exactly.
@Suite("Clipboard picker keys")
@MainActor
struct ClipPickerKeyTests {

    @Test
    func digitsPickAndEscapeCloses() {
        #expect(NotchViewModel.pickerAction(forKeyCode: 18, characters: "1") == .select(1))
        #expect(NotchViewModel.pickerAction(forKeyCode: 25, characters: "9") == .select(9))
        #expect(NotchViewModel.pickerAction(forKeyCode: 53, characters: nil) == .dismiss)
    }

    /// Zero has no row, and letters belong to whatever is underneath — neither
    /// may be swallowed.
    @Test
    func everythingElseIsLeftAlone() {
        #expect(NotchViewModel.pickerAction(forKeyCode: 29, characters: "0") == nil)
        #expect(NotchViewModel.pickerAction(forKeyCode: 0, characters: "a") == nil)
        #expect(NotchViewModel.pickerAction(forKeyCode: 49, characters: " ") == nil)
        #expect(NotchViewModel.pickerAction(forKeyCode: 36, characters: nil) == nil)
    }

    /// The picker gets its own window size. `isExpanded` still outranks it in
    /// the map, which is exactly why `showClipPicker` has to clear `isExpanded`
    /// itself — see `theChordCollapsesTheDashboardRatherThanBeingSwallowed`.
    @Test
    func thePickerHasItsOwnWindowTier() {
        #expect(NotchWindowController.tier(isExpanded: false, hudContent: .clipPicker) == .picker)
        #expect(NotchWindowController.tier(isExpanded: true, hudContent: .clipPicker) == .expanded)
        #expect(NotchWindowController.tier(isExpanded: false, hudContent: .peek) == .hud)
        #expect(NotchWindowController.tier(isExpanded: false, hudContent: nil) == .collapsed)
        #expect(NotchWindowController.pickerSize.height > NotchWindowController.hudSize.height)
    }

    /// The chord has to work from wherever the user pressed it, including with
    /// the dashboard open. Leaving `isExpanded` set meant the picker was
    /// invisible — and then fell out of the notch on its own later.
    @Test
    func theChordCollapsesTheDashboardRatherThanBeingSwallowed() {
        let presentation = NotchViewModel.clipPickerPresentation
        #expect(presentation.isExpanded == false)
        #expect(presentation.hudContent == .clipPicker)
        #expect(
            NotchWindowController.tier(
                isExpanded: presentation.isExpanded,
                hudContent: presentation.hudContent
            ) == .picker
        )
    }

    /// The keyboard is borrowed for the picker and has to be handed straight
    /// back. Leaving it with the notch meant the synthesized ⌘V was delivered
    /// to an overlay with no responder for it — the clip was copied and nothing
    /// was pasted — and the user's next keystrokes vanished too.
    @Test
    func theKeyboardGoesBackToWhoeverHadIt() {
        #expect(
            NotchPanel.handoff(borrowed: true, hasWindowToRestore: false, previousPID: 42, ownPID: 7)
                == .activate(pid: 42)
        )
        // A NotchHub window had it — Settings, or onboarding. Deactivating the
        // whole app here dropped the user behind whatever they had been in
        // before they opened Settings, and sent the paste there too.
        #expect(
            NotchPanel.handoff(borrowed: true, hasWindowToRestore: true, previousPID: 7, ownPID: 7)
                == .restoreWindow
        )
        #expect(
            NotchPanel.handoff(borrowed: true, hasWindowToRestore: true, previousPID: 42, ownPID: 7)
                == .restoreWindow
        )
        // Nobody to hand it back to: step out of the way instead of holding on.
        #expect(
            NotchPanel.handoff(borrowed: true, hasWindowToRestore: false, previousPID: nil, ownPID: 7)
                == .deactivateApp
        )
        #expect(
            NotchPanel.handoff(borrowed: true, hasWindowToRestore: false, previousPID: 7, ownPID: 7)
                == .deactivateApp
        )
        // Never borrowed it — the user just clicked the panel. Handing focus
        // away here took the app out from under a window they chose themselves.
        #expect(
            NotchPanel.handoff(borrowed: false, hasWindowToRestore: false, previousPID: 42, ownPID: 7)
                == .nothing
        )
        #expect(
            NotchPanel.handoff(borrowed: false, hasWindowToRestore: true, previousPID: 42, ownPID: 7)
                == .nothing
        )
    }

    /// The hand-off is a round trip through the window server, so the picker's
    /// paste has to wait longer than a paste that never moved focus.
    @Test
    func thePickerPasteWaitsForTheFocusHandoff() {
        #expect(PasteSynthesizer.focusHandoffDelay > PasteSynthesizer.defaultDelay)
    }

    /// The clip picker is something the user asked for and is reading; a copy
    /// or a charging notice must not replace it mid-selection.
    @Test
    func announcementsDoNotEvictThePicker() {
        #expect(
            NotchViewModel.shouldShowCopyHUD(popupEnabled: true, isExpanded: false, hudContent: .clipPicker)
                == false
        )
        #expect(
            NotchViewModel.shouldShowCopyHUD(popupEnabled: true, isExpanded: false, hudContent: .peek)
        )
    }
}
