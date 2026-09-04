import NotchHubMedia
import NotchHubSafeFeatures
import SwiftUI

public struct NotchPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model: AppPresentationModel
    private let geometry: NotchOverlayGeometry
    private let onHover: @MainActor (Bool) -> Void
    private let onDismiss: @MainActor () -> Void

    public init(
        model: AppPresentationModel,
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
                CompactAgentWings(model: model, cameraWidth: geometry.cameraWidth)
            } else {
                DirectNotchRibbon(
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.tier)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.pendingApproval)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchHub")
    }
}

private struct CompactAgentWings: View {
    let model: AppPresentationModel
    let cameraWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: cameraWidth)
            rightWing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, CompactNotchTheme.wingOuterPadding)
    }

    @ViewBuilder private var leftWing: some View {
        if let approval = model.pendingApproval {
            CompactStatusWing(
                symbol: "hand.raised.fill",
                value: approval.providerName,
                tint: .orange,
                alignment: .leading
            )
        } else if model.safeFeatures.focus.state != .idle {
            CompactStatusWing(symbol: "timer", value: "Focus", alignment: .leading)
        } else if let session = activeSession {
            CompactStatusWing(symbol: "bolt.fill", value: session.providerName, alignment: .leading)
        } else {
            CompactProviderWing(provider: provider(.codex), alignment: .leading)
        }
    }

    @ViewBuilder private var rightWing: some View {
        if model.pendingApproval != nil {
            CompactStatusWing(
                symbol: "exclamationmark.circle.fill",
                value: "Approval",
                tint: .orange,
                alignment: .trailing
            )
        } else if let media = model.media, media.hasActivity {
            CompactMediaWingView(model: media)
        } else if model.safeFeatures.focus.state != .idle {
            CompactFocusWing(model: model.safeFeatures.focus)
        } else if model.activeSessionCount > 0 {
            CompactStatusWing(
                symbol: "terminal",
                value: "\(model.activeSessionCount) active",
                alignment: .trailing
            )
        } else {
            CompactProviderWing(provider: provider(.claude), alignment: .trailing)
        }
    }

    private var activeSession: AgentSessionPresentation? {
        model.sessions.first { $0.status == .running || $0.status == .waitingForApproval }
    }

    private func provider(_ identifier: ProviderID) -> ProviderCardPresentation? {
        model.providers.first { $0.id == identifier.rawValue }
    }
}

private struct CompactStatusWing: View {
    let symbol: String
    let value: String
    var tint: Color = .white
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 4) {
            if alignment == .leading { Image(systemName: symbol) }
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if alignment == .trailing { Image(systemName: symbol) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

private struct CompactFocusWing: View {
    let model: FocusTimerModel

    var body: some View {
        HStack(spacing: 4) {
            Text(model.clockLabel)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(model.state == .completed ? .green : .white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Focus timer \(model.clockLabel), \(model.state.title)")
    }
}

private struct CompactProviderWing: View {
    let provider: ProviderCardPresentation?
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 4) {
            if alignment == .leading { providerIcon }
            Text(status)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if alignment == .trailing { providerIcon }
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var providerIcon: some View {
        Image(systemName: provider?.symbol ?? "ellipsis")
            .font(.system(size: 11, weight: .semibold))
    }

    private var status: String {
        if let value = provider?.highestUtilization {
            return "\(Int(value.rounded()))%"
        }
        return provider?.connection.label ?? "Checking"
    }

    private var tint: Color {
        provider?.connection.requiresAttention == true ? .orange : .white
    }

    private var accessibilityLabel: String {
        "\(provider?.name ?? "Provider") \(status)"
    }
}

private struct DirectNotchRibbon: View {
    let model: AppPresentationModel
    let cameraGapWidth: CGFloat
    let onDismiss: @MainActor () -> Void

    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            navigationBand
            HStack(alignment: .top, spacing: 12) {
                RibbonModuleHeader(
                    title: model.selectedCapability.title,
                    summary: model.selectedCapability.ribbonSummary,
                    symbol: model.selectedCapability.systemImage
                )
                .frame(
                    width: CompactNotchTheme.moduleHeaderWidth,
                    height: CompactNotchTheme.contentHeight
                )
                Divider().overlay(CompactNotchTheme.divider)
                selectedContent
                    .frame(maxWidth: .infinity, minHeight: CompactNotchTheme.contentHeight)
                    .clipped()
                    .id(model.selectedCapability)
                    .transition(.opacity)
            }
            .frame(height: CompactNotchTheme.contentHeight)
        }
        .padding(.horizontal, CompactNotchTheme.horizontalPadding)
        .padding(.vertical, CompactNotchTheme.verticalPadding)
    }

    private var navigationBand: some View {
        let capabilities = model.edition.capabilities
        let midpoint = (capabilities.count + 1) / 2
        return HStack(spacing: 0) {
            capabilityGroup(Array(capabilities.prefix(midpoint)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: cameraGapWidth)
            HStack(spacing: CompactNotchTheme.chipSpacing) {
                capabilityGroup(Array(capabilities.suffix(from: midpoint)))
                closeButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: CompactNotchTheme.navigationHeight)
    }

    private func capabilityGroup(_ capabilities: [AppCapability]) -> some View {
        HStack(spacing: CompactNotchTheme.chipSpacing) {
            ForEach(capabilities) { capability in
                DirectRibbonChip(
                    capability: capability,
                    isSelected: model.selectedCapability == capability,
                    selection: selection,
                    shortcut: shortcut(for: capability),
                    action: { model.select(capability) }
                )
            }
        }
    }

    private func shortcut(for capability: AppCapability) -> KeyEquivalent? {
        guard let index = model.edition.capabilities.firstIndex(of: capability) else { return nil }
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

    @ViewBuilder private var selectedContent: some View {
        switch model.selectedCapability {
        case .agents:
            CompactAgentsRow(model: model)
        case .dashboard:
            safeFeature(.dashboard)
        case .clipboard:
            safeFeature(.clipboard)
        case .focus:
            safeFeature(.focus)
        case .media:
            if let media = model.media {
                CompactMediaBarView(model: media)
            } else {
                CompactUnavailableCapability()
            }
        }
    }

    private func safeFeature(_ feature: SafeFeature) -> some View {
        CompactSafeFeatureView(feature: feature, workspace: model.safeFeatures)
    }
}

private struct DirectRibbonChip: View {
    let capability: AppCapability
    let isSelected: Bool
    let selection: Namespace.ID
    let shortcut: KeyEquivalent?
    let action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: capability.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                if isSelected {
                    Text(capability.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isSelected ? 10 : 0)
            .frame(minWidth: CompactNotchTheme.chipSize, minHeight: CompactNotchTheme.chipSize)
            .contentShape(Capsule())
        }
        .buttonStyle(
            DirectRibbonChipStyle(
                isSelected: isSelected,
                isHovered: isHovered,
                selection: selection
            )
        )
        .help(capability.title)
        .accessibilityLabel(capability.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .directRibbonKeyboardShortcut(shortcut)
    }
}

private struct DirectRibbonChipStyle: ButtonStyle {
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
                .matchedGeometryEffect(id: "direct-ribbon-selection", in: selection)
        } else {
            Capsule().fill(isHovered ? CompactNotchTheme.hoverSurface : CompactNotchTheme.subtleSurface)
        }
    }
}

private extension View {
    @ViewBuilder
    func directRibbonKeyboardShortcut(_ shortcut: KeyEquivalent?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut, modifiers: .command)
        } else {
            self
        }
    }
}

private struct CompactUnavailableCapability: View {
    var body: some View {
        Label("This module is not part of the compact preview.", systemImage: "eye.slash")
            .font(.system(size: 11))
            .foregroundStyle(CompactNotchTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private extension AppCapability {
    var ribbonSummary: String {
        switch self {
        case .agents: "Codex and Claude usage"
        case .dashboard: "System status at a glance"
        case .media: "Playback controls"
        case .clipboard: "Private, opt-in text history"
        case .focus: "A local focus timer"
        }
    }
}
