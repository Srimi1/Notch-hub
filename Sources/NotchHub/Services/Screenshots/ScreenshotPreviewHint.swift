import AppKit

/// Whether to explain why a copied screenshot arrives late.
///
/// macOS does not write the file until its floating preview finishes fading,
/// so with that preview on the copy lands several seconds after the shutter and
/// NotchHub looks slow for something it has no part in. The footer says this,
/// but a footer is not where anyone looks when a feature feels broken.
///
/// The hint is only worth showing when the preview is actually on, so this
/// reads Screenshot.app's own preference rather than nagging everyone. An unset
/// key means the macOS default, which is on.
enum ScreenshotPreviewHint {

    /// Screenshot.app's preference domain and the key holding the toggle from
    /// its Options menu.
    static let domain = "com.apple.screencapture"
    static let key = "show-thumbnail"

    /// Decides from the raw preference value. Pure so the rule is testable
    /// without a preference store: `nil` is an unset key, which macOS reads as
    /// the default, and the default is on.
    static func shouldExplainDelay(showsThumbnail: Bool?) -> Bool {
        showsThumbnail ?? true
    }

    /// Reads the live value from Screenshot.app's domain.
    ///
    /// Another application's preferences are readable here because NotchHub is
    /// not sandboxed. A domain that will not open is treated as unset, which
    /// errs toward showing the explanation rather than hiding it.
    static func showsThumbnail(
        defaults: UserDefaults? = UserDefaults(suiteName: domain)
    ) -> Bool? {
        defaults?.object(forKey: key) as? Bool
    }

    /// Opens Screenshot.app, where the toggle lives under Options.
    ///
    /// NotchHub does not write the preference itself: it belongs to another
    /// app, the user may well want the preview, and silently changing how their
    /// screenshots behave is not a decision a clipboard feature gets to make.
    @discardableResult
    static func openScreenshotApp() -> Bool {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
