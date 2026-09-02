import SwiftUI

/// The expanded dashboard. Header + horizontal module switcher on top; the
/// selected module's live body below. Every body is now backed by a real
/// service from `viewModel.services` — no placeholder data.
struct ExpandedDashboardView: View {

    @ObservedObject var viewModel: NotchViewModel
    private var services: ServiceHub { viewModel.services }

    /// Lets the selected-chip capsule travel between chips instead of blinking
    /// out of one and into the next.
    @Namespace private var chipSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if viewModel.presentedActivity != nil {
            ActivityDetailView(
                viewModel: viewModel,
                coordinator: services.activityCoordinator
            )
        } else {
            moduleDashboard
        }
    }

    private var moduleDashboard: some View {
        VStack(alignment: .leading, spacing: NotchTheme.dashboardRowSpacing) {
            toggleBand

            if visibleModules.isEmpty {
                // Hiding every module is a supported choice, so say what
                // happened rather than rendering a module the user just hid.
                EmptyHint(
                    symbol: "square.grid.2x2",
                    text: "Every module is hidden. Turn one back on in Settings ▸ Modules."
                )
                .frame(maxWidth: .infinity, minHeight: NotchTheme.contentHeight, alignment: .leading)
            } else {
                moduleRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var moduleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            moduleHeader
                .frame(
                    width: NotchTheme.moduleHeaderWidth,
                    height: NotchTheme.contentHeight,
                    alignment: .topLeading
                )
            Divider().overlay(NotchTheme.divider)
            moduleBody
                .frame(
                    maxWidth: .infinity,
                    minHeight: NotchTheme.contentHeight,
                    maxHeight: NotchTheme.contentHeight,
                    alignment: .leading
                )
                .clipped()
                // Keyed on the module so switching cross-fades the whole body
                // rather than mutating one view's contents in place.
                .id(viewModel.activeModule)
                .transition(.opacity)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: NotchTheme.contentHeight,
            maxHeight: NotchTheme.contentHeight,
            alignment: .leading
        )
    }

    /// Module toggles split into two groups that flank the physical notch, with
    /// a gap in the middle sized to the camera housing — so no button is ever
    /// hidden behind the notch.
    private var toggleBand: some View {
        let mid = (visibleModules.count + 1) / 2
        return HStack(spacing: 0) {
            toggleGroup(Array(visibleModules.prefix(mid)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: viewModel.notchSize.width + 24)
            toggleGroup(Array(visibleModules.suffix(from: mid)))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: max(viewModel.notchSize.height, NotchTheme.navigationHeight))
    }

    private func toggleGroup(_ modules: [FeatureModule]) -> some View {
        HStack(spacing: NotchTheme.chipSpacing) {
            ForEach(modules) { module in
                ModuleChip(
                    module: module,
                    isSelected: module == viewModel.activeModule,
                    shortcut: keyboardShortcut(for: module),
                    selectionNamespace: chipSelection
                ) {
                    withAnimation(moduleAnimation) { viewModel.select(module) }
                }
            }
        }
    }

    /// Matches the notch's own expand/collapse feel, and collapses to a near
    /// instant cut under Reduce Motion — the same rule `NotchViewModel` uses.
    private var moduleAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    private func keyboardShortcut(for module: FeatureModule) -> KeyEquivalent? {
        guard let index = visibleModules.firstIndex(of: module) else { return nil }
        return ModuleKeyboardShortcut.key(at: index)
    }

    private var visibleModules: [FeatureModule] {
        viewModel.preferences.visibleModules
    }

    private var moduleHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: viewModel.activeModule.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: NotchTheme.cardRadius).fill(Color.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.activeModule.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(viewModel.activeModule.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var moduleBody: some View {
        switch viewModel.activeModule {
        case .dashboard:
            DashboardModuleView(
                time: services.time,
                battery: services.battery,
                system: services.system,
                batteryWarningPercent: services.activityPreferences.batteryWarningPercent
            )
        case .media:
            MediaModuleView(media: services.media)
        case .calendar:
            CalendarModuleView(calendar: services.calendar)
        case .pomodoro:
            TimerModuleView(timers: services.timers)
        case .todo:
            ReminderModuleView(reminders: services.reminders)
        case .clipboard:
            ClipboardModuleView(
                clipboard: services.clipboard,
                hint: "Click to copy. The clipboard shortcut picks and pastes in one go."
            ) { viewModel.copyWithoutPaste($0) }
        case .focus:
            FocusModuleView(
                focus: services.focus,
                cleanup: services.cacheCleanup,
                preferences: services.cleanupPreferences
            )
        }
    }
}

// MARK: - Calendar (real EventKit)

private struct CalendarModuleView: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        switch calendar.access {
        case .denied:
            EmptyHint(
                symbol: "calendar.badge.exclamationmark",
                text: calendar.lastError ?? "Enable Calendar access in System Settings ▸ Privacy."
            )
        case .unknown:
            // Nothing requests access on its own any more, so this state has to
            // offer the action rather than narrate a request that is not happening.
            HStack(spacing: 10) {
                EmptyHint(symbol: "calendar", text: "Allow access to show upcoming events.")
                Button("Enable Calendar") { calendar.requestAccess() }
                    .buttonStyle(.borderedProminent)
            }
        case .granted where calendar.events.isEmpty:
            EmptyHint(symbol: "calendar", text: "Nothing on the calendar for the next two days.")
        case .granted:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(calendar.events.prefix(6)) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Text(event.isAllDay ? "All day" : RelativeTime.clock(event.start))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 124, height: 38, alignment: .topLeading)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: NotchTheme.cardRadius)
                                .fill(NotchTheme.subtleSurface)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Clipboard (recent text snippets)

private struct ClipboardModuleView: View {
    @ObservedObject var clipboard: ClipboardService
    let hint: String
    let onPick: (ClipboardService.Clip) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if clipboard.clips.isEmpty {
                EmptyHint(symbol: "doc.on.clipboard", text: "Copy text, an image, or a file to collect it here.")
            } else {
                clipRow
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var clipRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(clipboard.clips) { clip in
                        Button {
                            onPick(clip)
                        } label: {
                            ClipTile(clip: clip, thumbnail: clipboard.thumbnails[clip.id])
                        }
                        .buttonStyle(NotchButtonStyle(shape: .card))
                    }
                }
            }

            Button {
                clipboard.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(NotchButtonStyle(shape: .circle))
        }
    }
}

/// A single clipboard entry. Visual clips (images/videos/files) show a
/// thumbnail; text clips show their content.
private struct ClipTile: View {
    let clip: ClipboardService.Clip
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 7) {
            if clip.isVisual {
                thumbView
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.preview)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(RelativeTime.ago(clip.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .frame(width: clip.isVisual ? 150 : 136, height: 38, alignment: .leading)
        .padding(6)
        // The style owns the fill and the hit shape together. Before it, the
        // plain button hit-tested only the drawn text, so clicks in the padding
        // fell through and missed the tile entirely.
    }

    @ViewBuilder
    private var thumbView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: NotchTheme.innerRadius))
        } else {
            RoundedRectangle(cornerRadius: NotchTheme.innerRadius)
                .fill(Color.white.opacity(0.1))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: clip.symbol).font(.system(size: 14)))
        }
    }
}

struct EmptyHint: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
