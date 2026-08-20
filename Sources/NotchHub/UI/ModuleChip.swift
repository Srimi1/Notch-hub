import SwiftUI

struct ModuleChip: View {
    let module: FeatureModule
    let isSelected: Bool
    let shortcut: KeyEquivalent?
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
            .background(Capsule().fill(backgroundColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(module.title)
        .accessibilityLabel(module.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .onHover { isHovered = $0 }
        .notchKeyboardShortcut(shortcut)
    }

    private var backgroundColor: Color {
        if isSelected { return NotchTheme.selectedSurface }
        if isHovered { return Color.white.opacity(0.12) }
        return NotchTheme.subtleSurface
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
