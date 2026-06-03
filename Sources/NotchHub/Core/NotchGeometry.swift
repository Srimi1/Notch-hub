import AppKit

/// Resolves the position and size of the physical notch (or a sensible
/// fallback on notch-less Macs / external displays) for a given screen.
///
/// On notched MacBooks the menu bar is split into two "auxiliary" areas that
/// flank the camera housing. The notch width is therefore:
///     screen.width − leftAuxiliaryArea.width − rightAuxiliaryArea.width
/// and the notch height equals the top safe-area inset (the menu-bar height).
struct NotchGeometry {

    let screen: NSScreen
    let hasPhysicalNotch: Bool
    /// Size of the collapsed pill — matches the physical notch when present.
    let notchSize: CGSize

    // Fallback dimensions for displays without a physical notch.
    static let fallbackWidth: CGFloat = 190
    static let fallbackHeight: CGFloat = 32

    init(screen: NSScreen) {
        self.screen = screen

        let menuBarHeight = screen.safeAreaInsets.top
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let totalWidth = screen.frame.width

        let looksNotched =
            menuBarHeight > 0 &&
            leftWidth > 0 &&
            rightWidth > 0 &&
            (leftWidth + rightWidth) < totalWidth

        if looksNotched {
            let notchWidth = totalWidth - leftWidth - rightWidth
            self.hasPhysicalNotch = true
            self.notchSize = CGSize(width: notchWidth, height: menuBarHeight)
        } else {
            self.hasPhysicalNotch = false
            self.notchSize = CGSize(
                width: Self.fallbackWidth,
                height: max(menuBarHeight, Self.fallbackHeight)
            )
        }
    }
}
