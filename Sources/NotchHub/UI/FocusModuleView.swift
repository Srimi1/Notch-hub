import SwiftUI

/// The Focus module: Do Not Disturb on the left, and — when it is switched on
/// — how much rebuildable cache is on disk on the right.
///
/// Two segments rather than two modules. They share the row because they share
/// an occasion: the moment someone opens the notch to quieten their Mac is the
/// same moment they will tidy it. The divider is the one `TimerModuleView`
/// uses, and the whole thing still lives inside the fixed 68pt module body.
struct FocusModuleView: View {
    @ObservedObject var focus: FocusService
    @ObservedObject var cleanup: CacheCleanupService
    @Bindable var preferences: CleanupPreferences

    var body: some View {
        HStack(spacing: 12) {
            FocusStatusSegment(focus: focus)
            if preferences.showInFocus {
                Divider().overlay(NotchTheme.divider)
                CacheCleanupSegment(cleanup: cleanup)
                    .frame(width: CacheCleanupSegment.width)
            }
        }
        .onAppear {
            focus.refreshAccessibility()
            if preferences.showInFocus { cleanup.refreshIfStale() }
        }
    }
}

// MARK: - Do Not Disturb

private struct FocusStatusSegment: View {
    @ObservedObject var focus: FocusService

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(3)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let pane = focus.lastError?.settingsPane {
                Button("Fix…") {
                    if pane == .accessibility {
                        focus.requestAccessibility()
                    }
                    pane.open()
                }
                .buttonStyle(NotchButtonStyle(shape: .capsule))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
            }

            toggleButton
        }
    }

    private var toggleButton: some View {
        Button {
            focus.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.fill")
                Text(toggleTitle)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isShowingOn ? .black : .white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Capsule().fill(isShowingOn ? Color.purple.opacity(0.9) : NotchTheme.hoverSurface)
            )
        }
        .buttonStyle(NotchButtonStyle(shape: .bare))
        .disabled(focus.isToggling)
    }

    /// Only claim "on" when the state was actually read; otherwise the button
    /// would promise the opposite of what the click does.
    private var isShowingOn: Bool { focus.isStateKnown && focus.isOn }

    private var toggleTitle: String {
        guard focus.isStateKnown else { return "Toggle" }
        return focus.isOn ? "Turn Off" : "Turn On"
    }

    private var statusTitle: String {
        if focus.isToggling { return "Switching Do Not Disturb…" }
        switch focus.lastError {
        case .accessibilityDenied: return "Accessibility permission needed"
        case .automationDenied: return "Automation permission needed"
        case .controlNotFound: return "Could not find the Focus control"
        case .scriptFailed: return "Could not switch Do Not Disturb"
        case nil:
            guard focus.isStateKnown else { return "Do Not Disturb" }
            return focus.isOn ? "Do Not Disturb is on" : "Do Not Disturb is off"
        }
    }

    private var statusSubtitle: String {
        switch focus.lastError {
        case .accessibilityDenied:
            return "Allow NotchHub in \(SystemSettingsPane.accessibility.settingsPath), then try again."
        case .automationDenied:
            return "Allow NotchHub to control System Events in "
                + "\(SystemSettingsPane.automation.settingsPath)."
        case .controlNotFound:
            return "Control Center did not show a Do Not Disturb control. "
                + "On a Mac that isn't set to English, macOS may name it differently."
        case .scriptFailed:
            return "macOS refused the request. Try again in a moment."
        case nil:
            guard focus.isStateKnown else {
                return "Silences notifications across your Mac. Reading whether it's already on "
                    + "needs \(SystemSettingsPane.fullDiskAccess.settingsPath)."
            }
            return "Silences notifications across your Mac."
        }
    }
}

// MARK: - Cache cleanup

private struct CacheCleanupSegment: View {
    /// Wide enough for "1.23 GB safe to clean" and a 64pt button, narrow
    /// enough to leave the Focus status three readable lines.
    static let width: CGFloat = 272

    @ObservedObject var cleanup: CacheCleanupService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: CleanupCopy {
        CleanupCopy.make(state: cleanup.state, now: .now)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                Text(copy.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(copy.isError ? Color.red : NotchTheme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: cleanup.state)
    }

    private var titleLine: some View {
        HStack(spacing: 4) {
            Image(systemName: copy.symbol)
                .foregroundStyle(copy.isError ? Color.red : .white)
            Text(copy.title)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
    }

    private var actionButton: some View {
        Button(copy.action.title) { perform(copy.action) }
            .buttonStyle(NotchButtonStyle(shape: .capsule))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 32)
            .disabled(!copy.isActionEnabled)
            .accessibilityLabel(copy.accessibilityLabel)
    }

    private func perform(_ action: CleanupCopy.Action) {
        switch action {
        case .scan, .rescan, .retry: cleanup.scan()
        case .clean: cleanup.cleanSafe()
        case let .openSettings(pane): pane.open()
        }
    }
}
