import AppKit

extension NSScreen {
    /// The screen NotchHub should attach to. Prefer a screen that has a
    /// physical notch; otherwise fall back to the main screen, then the first
    /// available screen.
    static var notchScreen: NSScreen? {
        if let notched = NSScreen.screens.first(where: { screen in
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            return screen.safeAreaInsets.top > 0 &&
                leftWidth > 0 &&
                rightWidth > 0 &&
                (leftWidth + rightWidth) < screen.frame.width
        }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
