import SwiftUI

/// How a control on the overlay is answering the pointer right now.
///
/// Split out as a value so the rule is a pure function that a test can drive,
/// rather than something only observable by hovering a running app.
enum NotchInteraction: Equatable, Sendable {
    case resting
    case hovered
    case pressed

    /// Pressed wins over hovered: the pointer is necessarily over a control it
    /// is pressing, and the more urgent fact is that the click is happening.
    static func state(isHovered: Bool, isPressed: Bool) -> NotchInteraction {
        if isPressed { return .pressed }
        return isHovered ? .hovered : .resting
    }

    var surface: Color {
        switch self {
        case .resting: NotchTheme.subtleSurface
        case .hovered: NotchTheme.hoverSurface
        case .pressed: NotchTheme.pressedSurface
        }
    }
}

/// One interaction vocabulary for every control on the notch overlay.
///
/// The bug this replaces: every button on the panel used `.buttonStyle(.plain)`,
/// which strips hover, pressed and focus together and puts nothing back. Fifteen
/// controls across seven files therefore looked identical whether the pointer was
/// over them, pressing them, or somewhere else entirely.
///
/// That is worse on this surface than it would be in an ordinary window. The
/// targets are 30pt, the panel floats over whatever the user was doing, and no
/// menu bar, title bar or cursor change corroborates a click. Feedback is the
/// only thing that says the control is a control.
struct NotchButtonStyle: ButtonStyle {

    /// The shape the fill is drawn in — and the hit area, which is the same
    /// thing. Padding outside `contentShape` is padding that ignores clicks.
    enum Shape: Equatable, Sendable {
        case card
        case capsule
        case circle
        /// For controls that draw their own fill because they need it for
        /// something else — `ModuleChip` carries a `matchedGeometryEffect` on
        /// its selected capsule. They get press feedback and nothing more.
        case bare
    }

    var shape: Shape = .card

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, shape: shape)
    }

    private struct Surface: View {
        let configuration: Configuration
        let shape: Shape

        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var state: NotchInteraction {
            guard isEnabled else { return .resting }
            return NotchInteraction.state(isHovered: isHovered, isPressed: configuration.isPressed)
        }

        var body: some View {
            configuration.label
                .background(background)
                .contentShape(hitShape)
                .opacity(opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state)
                .onHover { isHovered = $0 }
        }

        /// A disabled control is dimmed rather than recoloured: the panel has no
        /// grey to reach for, only opacities of white, and a "disabled fill"
        /// would land between subtle and hover and read as a hover.
        private var opacity: Double {
            if !isEnabled { return 0.35 }
            return shape == .bare && configuration.isPressed ? 0.7 : 1
        }

        @ViewBuilder
        private var background: some View {
            switch shape {
            case .card: RoundedRectangle(cornerRadius: NotchTheme.cardRadius).fill(state.surface)
            case .capsule: Capsule().fill(state.surface)
            case .circle: Circle().fill(state.surface)
            case .bare: EmptyView()
            }
        }

        private var hitShape: AnyShape {
            switch shape {
            case .card: AnyShape(RoundedRectangle(cornerRadius: NotchTheme.cardRadius))
            case .capsule, .bare: AnyShape(Capsule())
            case .circle: AnyShape(Circle())
            }
        }
    }
}
