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

    /// Radius for a thumbnail or glyph nested inside a card, kept concentric
    /// with `cardRadius` at the 3pt inset the panel's cards use. It existed
    /// already as three different literals — 5 twice, 6 twice — which is how
    /// concentric curves stop being concentric.
    static let innerRadius: CGFloat = cardRadius - 3

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

    /// Fill under the pointer. Sits between subtle (1.12:1) and selected
    /// (1.54:1) so a hover reads as "this responds" without being mistaken for
    /// a selection that stays. 1.27:1 against the panel.
    static let hoverSurface = Color.white.opacity(0.12)

    /// Fill while the pointer is down. Deliberately stronger than
    /// `selectedSurface` at 1.79:1: it lasts only as long as the mouse button
    /// does, so it cannot be read as a selection, and on a panel floating over
    /// another app it is the only confirmation the click landed at all.
    static let pressedSurface = Color.white.opacity(0.22)
    static let divider = Color.white.opacity(0.14)
    static let secondaryText = Color.white.opacity(0.68)
}
