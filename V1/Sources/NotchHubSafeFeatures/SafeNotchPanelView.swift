import SwiftUI

public struct SafeNotchPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model: SafeNotchPresentationModel
    private let geometry: NotchOverlayGeometry
    private let onHover: @MainActor (Bool) -> Void
    private let onDismiss: @MainActor () -> Void

    public init(
        model: SafeNotchPresentationModel,
        geometry: NotchOverlayGeometry,
        onHover: @escaping @MainActor (Bool) -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.geometry = geometry
        self.onHover = onHover
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if model.tier == .compact {
                SafeCompactWings(model: model, cameraWidth: geometry.cameraWidth)
            } else {
                SafeNotchRibbon(
                    model: model,
                    cameraGapWidth: geometry.navigationGapWidth,
                    onDismiss: onDismiss
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            CompactNotchBackground(
                hasPhysicalNotch: geometry.hasPhysicalNotch,
                isExpanded: model.tier == .detail
            )
        )
        .foregroundStyle(.white)
        .onHover(perform: onHover)
        .onAppear { model.workspace.start() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.tier)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchHub Lite")
    }
}

private struct SafeCompactWings: View {
    let model: SafeNotchPresentationModel
    let cameraWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            CompactWingValue(
                symbol: "cpu",
                value: model.workspace.dashboard.snapshot.activeProcessorCount.formatted(),
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: cameraWidth)
            CompactWingValue(
                symbol: "timer",
                value: model.workspace.focus.clockLabel,
                alignment: .trailing
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, CompactNotchTheme.wingOuterPadding)
    }
}

private struct CompactWingValue: View {
    let symbol: String
    let value: String
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 4) {
            if alignment == .leading {
                Image(systemName: symbol)
            }
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if alignment == .trailing {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private struct SafeNotchRibbon: View {
    let model: SafeNotchPresentationModel
    let cameraGapWidth: CGFloat
    let onDismiss: @MainActor () -> Void

    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            navigationBand
            HStack(alignment: .top, spacing: 12) {
                moduleHeader
                    .frame(
                        width: CompactNotchTheme.moduleHeaderWidth,
                        height: CompactNotchTheme.contentHeight
                    )
                Divider().overlay(CompactNotchTheme.divider)
                CompactSafeFeatureView(feature: model.selectedFeature, workspace: model.workspace)
                    .frame(maxWidth: .infinity, minHeight: CompactNotchTheme.contentHeight)
                    .clipped()
                    .id(model.selectedFeature)
                    .transition(.opacity)
            }
            .frame(height: CompactNotchTheme.contentHeight)
        }
        .padding(.horizontal, CompactNotchTheme.horizontalPadding)
        .padding(.vertical, CompactNotchTheme.verticalPadding)
    }

    private var navigationBand: some View {
        let midpoint = (SafeFeature.allCases.count + 1) / 2
        return HStack(spacing: 0) {
            featureGroup(Array(SafeFeature.allCases.prefix(midpoint)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: cameraGapWidth)
            HStack(spacing: CompactNotchTheme.chipSpacing) {
                featureGroup(Array(SafeFeature.allCases.suffix(from: midpoint)))
                closeButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: CompactNotchTheme.navigationHeight)
    }

    private func featureGroup(_ features: [SafeFeature]) -> some View {
        HStack(spacing: CompactNotchTheme.chipSpacing) {
            ForEach(features) { feature in
                RibbonChip(
                    title: feature.title,
                    symbol: feature.systemImage,
                    isSelected: model.selectedFeature == feature,
                    selection: selection,
                    shortcut: shortcut(for: feature),
                    action: { model.select(feature) }
                )
            }
        }
    }

    private func shortcut(for feature: SafeFeature) -> KeyEquivalent? {
        guard let index = SafeFeature.allCases.firstIndex(of: feature) else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: CompactNotchTheme.chipSize, height: CompactNotchTheme.chipSize)
                .background(CompactNotchTheme.subtleSurface, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Collapse NotchHub")
        .accessibilityLabel("Collapse NotchHub")
    }

    private var moduleHeader: some View {
        RibbonModuleHeader(
            title: model.selectedFeature.title,
            summary: model.selectedFeature.ribbonSummary,
            symbol: model.selectedFeature.systemImage
        )
    }
}

public struct RibbonModuleHeader: View {
    private let title: String
    private let summary: String
    private let symbol: String

    public init(title: String, summary: String, symbol: String) {
        self.title = title
        self.summary = summary
        self.symbol = symbol
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(CompactNotchTheme.hoverSurface, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(CompactNotchTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

private struct RibbonChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let selection: Namespace.ID
    let shortcut: KeyEquivalent?
    let action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if isSelected {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
            }
            .padding(.horizontal, isSelected ? 10 : 0)
            .frame(minWidth: CompactNotchTheme.chipSize, minHeight: CompactNotchTheme.chipSize)
            .contentShape(Capsule())
        }
        .buttonStyle(
            RibbonChipStyle(
                isSelected: isSelected,
                isHovered: isHovered,
                selection: selection
            )
        )
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .ribbonKeyboardShortcut(shortcut)
    }
}

private struct RibbonChipStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    let selection: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { background(isPressed: configuration.isPressed) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder private func background(isPressed: Bool) -> some View {
        if isPressed {
            Capsule().fill(CompactNotchTheme.pressedSurface)
        } else if isSelected {
            Capsule()
                .fill(CompactNotchTheme.selectedSurface)
                .matchedGeometryEffect(id: "safe-ribbon-selection", in: selection)
        } else {
            Capsule().fill(isHovered ? CompactNotchTheme.hoverSurface : CompactNotchTheme.subtleSurface)
        }
    }
}

private extension View {
    @ViewBuilder
    func ribbonKeyboardShortcut(_ shortcut: KeyEquivalent?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut, modifiers: .command)
        } else {
            self
        }
    }
}

private extension SafeFeature {
    var ribbonSummary: String {
        switch self {
        case .dashboard: "System status at a glance"
        case .clipboard: "Private, opt-in text history"
        case .focus: "A local focus timer"
        }
    }
}
