import Foundation
import Testing
@testable import NotchHub

/// The copy cannot arrive before macOS writes the file, and macOS waits for its
/// floating preview to fade. The explanation for that is only worth showing to
/// the people it applies to.
@Suite("Screenshot preview delay hint")
struct ScreenshotPreviewHintTests {

    @Test
    func explainsTheDelayWhileThePreviewIsOn() {
        #expect(ScreenshotPreviewHint.shouldExplainDelay(showsThumbnail: true))
    }

    /// With the preview off the file is written at the shutter, so there is no
    /// delay to explain and the hint would just be noise.
    @Test
    func staysQuietWhenThePreviewIsOff() {
        #expect(!ScreenshotPreviewHint.shouldExplainDelay(showsThumbnail: false))
    }

    /// An unset key is the macOS default, and that default is on. Erring the
    /// other way would hide the explanation from everyone who has never opened
    /// Screenshot.app's options, which is most people.
    @Test
    func treatsAnUnsetPreferenceAsTheMacOSDefault() {
        #expect(ScreenshotPreviewHint.shouldExplainDelay(showsThumbnail: nil))
    }

    /// The value is read from Screenshot.app's own domain, so a store that does
    /// not hold the key reads as unset rather than as off.
    @Test
    func readsTheKeyFromAGivenStore() throws {
        let suite = "notchhub.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ScreenshotPreviewHint.showsThumbnail(defaults: defaults) == nil)
        defaults.set(false, forKey: ScreenshotPreviewHint.key)
        #expect(ScreenshotPreviewHint.showsThumbnail(defaults: defaults) == false)
        defaults.set(true, forKey: ScreenshotPreviewHint.key)
        #expect(ScreenshotPreviewHint.showsThumbnail(defaults: defaults) == true)
    }

    /// The domain and key are Screenshot.app's, not NotchHub's; a typo here
    /// would silently read nothing and show the hint to everybody forever.
    @Test
    func pointsAtScreenshotAppsOwnPreference() {
        #expect(ScreenshotPreviewHint.domain == "com.apple.screencapture")
        #expect(ScreenshotPreviewHint.key == "show-thumbnail")
    }
}
