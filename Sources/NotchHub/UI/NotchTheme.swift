import SwiftUI

enum NotchTheme {
    static let expandedWidth: CGFloat = 860
    static let expandedHeight: CGFloat = 136
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let navigationHeight: CGFloat = 32
    static let contentHeight: CGFloat = 68
    static let moduleHeaderWidth: CGFloat = 150
    static let inactiveChipSize: CGFloat = 30
    static let chipSpacing: CGFloat = 7
    static let cardRadius: CGFloat = 9

    /// Spacing between the dashboard's toggle band and its module row.
    static let dashboardRowSpacing: CGFloat = 8

    /// Dashboard height for a given notch.
    ///
    /// The toggle band reserves the notch's own height so the chips flank the
    /// camera, which means a taller notch needs a taller window: on the 14"
    /// and 16" MacBook Pros the band alone is enough to push the module row
    /// past the fixed 136pt and out through the bottom of the panel.
    static func expandedHeight(notchHeight: CGFloat) -> CGFloat {
        let intrinsic = verticalPadding * 2
            + max(notchHeight, navigationHeight)
            + dashboardRowSpacing
            + contentHeight
        return max(expandedHeight, intrinsic)
    }

    static let subtleSurface = Color.white.opacity(0.07)
    static let selectedSurface = Color.white.opacity(0.18)
    static let divider = Color.white.opacity(0.14)
    static let secondaryText = Color.white.opacity(0.68)
}
