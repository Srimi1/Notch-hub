import SwiftUI

struct ModuleChip: View {
    let module: FeatureModule
    let isSelected: Bool
    let shortcut: KeyEquivalent?
    /// Shared with the other chips so the selected capsule slides between them.
    let selectionNamespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: module.symbol)
                    .font(.system(size: 11, weight: .semibold))
                if isSelected {
                    Text(module.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isSelected ? 10 : 0)
            .frame(minWidth: NotchTheme.inactiveChipSize)
            .frame(height: NotchTheme.inactiveChipSize)
            .background(chipBackground)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(module.title)
        .accessibilityLabel(module.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .onHover { isHovered = $0 }
        .notchKeyboardShortcut(shortcut)
    }

    @ViewBuilder
    private var chipBackground: some View {
        if isSelected {
            Capsule()
                .fill(NotchTheme.selectedSurface)
                .matchedGeometryEffect(id: "selectedChip", in: selectionNamespace)
        } else {
            Capsule().fill(isHovered ? Color.white.opacity(0.12) : NotchTheme.subtleSurface)
        }
    }
}

private extension View {
    @ViewBuilder
    func notchKeyboardShortcut(_ shortcut: KeyEquivalent?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut, modifiers: .command)
        } else {
            self
        }
    }
}

enum ModuleKeyboardShortcut {
    static func key(at index: Int) -> KeyEquivalent? {
        guard 0 ..< 9 ~= index else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
}
