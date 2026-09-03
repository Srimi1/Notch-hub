import SwiftUI

/// Geometry and visual tokens inherited from NotchHub 0.5-0.7's shallow
/// overlay. The panel is hardware-shaped: content is shortened to fit rather
/// than making the notch grow into an ordinary window.
public enum CompactNotchTheme {
    public static let compactWidth: CGFloat = 190
    public static let compactHeight: CGFloat = 32
    public static let expandedWidth: CGFloat = 860
    public static let expandedHeight: CGFloat = 136
    public static let horizontalPadding: CGFloat = 16
    public static let verticalPadding: CGFloat = 12
    public static let navigationHeight: CGFloat = 32
    public static let contentHeight: CGFloat = 68
    public static let moduleHeaderWidth: CGFloat = 150
    public static let cameraGapPadding: CGFloat = 24
    public static let wingWidth: CGFloat = 112
    public static let wingOuterPadding: CGFloat = 12
    public static let chipSize: CGFloat = 30
    public static let chipSpacing: CGFloat = 7
    public static let cardRadius: CGFloat = 9

    public static let subtleSurface = Color.white.opacity(0.07)
    public static let selectedSurface = Color.white.opacity(0.18)
    public static let hoverSurface = Color.white.opacity(0.12)
    public static let pressedSurface = Color.white.opacity(0.22)
    public static let divider = Color.white.opacity(0.14)
    public static let secondaryText = Color.white.opacity(0.68)

    public static func expandedHeight(notchHeight: CGFloat) -> CGFloat {
        let intrinsic = verticalPadding * 2
            + max(notchHeight, navigationHeight)
            + 8
            + contentHeight
        return max(expandedHeight, intrinsic)
    }
}

/// The common true-black silhouette used by both V1 editions.
public struct CompactNotchBackground: View {
    private let hasPhysicalNotch: Bool
    private let isExpanded: Bool

    public init(hasPhysicalNotch: Bool, isExpanded: Bool) {
        self.hasPhysicalNotch = hasPhysicalNotch
        self.isExpanded = isExpanded
    }

    public var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: hasPhysicalNotch ? 0 : radius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: hasPhysicalNotch ? 0 : radius
        )
        .fill(.black.opacity(hasPhysicalNotch ? 1 : 0.82))
        .shadow(color: .black.opacity(0.28), radius: isExpanded ? 10 : 5, y: 4)
    }

    private var radius: CGFloat {
        isExpanded ? 24 : 10
    }
}
