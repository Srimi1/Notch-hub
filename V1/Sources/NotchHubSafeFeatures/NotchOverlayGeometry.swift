import AppKit

/// Pure geometry contract for the physical notch and notchless fallback.
public struct NotchOverlayGeometry: Sendable, Equatable {
    private static let plausibleCameraWidth: ClosedRange<CGFloat> = 80 ... 400
    private static let plausibleCameraHeight: ClosedRange<CGFloat> = 24 ... 64

    public let hasPhysicalNotch: Bool
    public let cameraWidth: CGFloat
    public let cameraHeight: CGFloat

    public init(
        screenWidth: CGFloat,
        safeAreaTop: CGFloat,
        leftAuxiliaryWidth: CGFloat,
        rightAuxiliaryWidth: CGFloat
    ) {
        let inferredCameraWidth = screenWidth - leftAuxiliaryWidth - rightAuxiliaryWidth
        let metricsAreFinite = screenWidth.isFinite
            && safeAreaTop.isFinite
            && leftAuxiliaryWidth.isFinite
            && rightAuxiliaryWidth.isFinite
        let looksNotched = metricsAreFinite
            && screenWidth > 0
            && leftAuxiliaryWidth > 0
            && rightAuxiliaryWidth > 0
            && Self.plausibleCameraHeight.contains(safeAreaTop)
            && Self.plausibleCameraWidth.contains(inferredCameraWidth)
            && inferredCameraWidth <= screenWidth * 0.4
        hasPhysicalNotch = looksNotched
        cameraWidth = looksNotched
            ? inferredCameraWidth
            : CompactNotchTheme.compactWidth
        cameraHeight = looksNotched
            ? safeAreaTop
            : CompactNotchTheme.compactHeight
    }

    @MainActor
    public init(screen: NSScreen) {
        self.init(
            screenWidth: screen.frame.width,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width ?? 0
        )
    }

    public var navigationGapWidth: CGFloat {
        cameraWidth + CompactNotchTheme.cameraGapPadding
    }

    public func compactSize(showsWings: Bool) -> CGSize {
        var width = cameraWidth
        if showsWings {
            width += 2 * (CompactNotchTheme.wingWidth + CompactNotchTheme.wingOuterPadding)
        }
        return CGSize(width: width, height: cameraHeight)
    }

    public func expandedSize(availableWidth: CGFloat) -> CGSize {
        let usableWidth = availableWidth.isFinite ? max(0, availableWidth - 40) : 0
        return CGSize(
            width: min(CompactNotchTheme.expandedWidth, usableWidth),
            height: CompactNotchTheme.expandedHeight(notchHeight: cameraHeight)
        )
    }
}

/// Pure frame policy shared by both app controllers so screen anchoring can be
/// verified independently from AppKit event delivery.
public enum NotchOverlayFramePolicy {
    public static func frame(
        in screenFrame: CGRect,
        geometry: NotchOverlayGeometry,
        isExpanded: Bool,
        showsWings: Bool
    ) -> CGRect {
        let size = isExpanded
            ? geometry.expandedSize(availableWidth: screenFrame.width)
            : geometry.compactSize(showsWings: showsWings)
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
