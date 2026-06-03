import SwiftUI

/// The expanded dashboard. Header + horizontal module switcher on top; the
/// selected module's live body below. Every body is now backed by a real
/// service from `viewModel.services` — no placeholder data.
struct ExpandedDashboardView: View {

    @ObservedObject var viewModel: NotchViewModel
    private var services: ServiceHub { viewModel.services }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggleBand

            HStack(alignment: .top, spacing: 12) {
                moduleHeader
                    .frame(width: 160, height: 46)
                Divider().overlay(Color.white.opacity(0.12))
                moduleBody
                    .frame(height: 46)
                    .clipped()
            }
            .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .frame(height: max(viewModel.notchSize.height, 30))
    }

    private func toggleGroup(_ modules: [FeatureModule]) -> some View {
        HStack(spacing: 7) {
            ForEach(modules) { module in
                Button {
                    viewModel.select(module)
                } label: {
                    Label(module.title, systemImage: module.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(module == viewModel.activeModule ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .help(module.title)
            }
        }
    }

    private var visibleModules: [FeatureModule] {
        viewModel.preferences.visibleModules
    }

    private var moduleHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: viewModel.activeModule.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.activeModule.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(viewModel.activeModule.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var moduleBody: some View {
        switch viewModel.activeModule {
        case .dashboard:
            DashboardModuleView(services: services)
        case .media:
            MediaModuleView(media: services.media)
        case .calendar:
            CalendarModuleView(calendar: services.calendar)
        case .aiCoding:
            AICodingModuleView(aiCoding: services.aiCoding)
        case .clipboard:
            ClipboardModuleView(clipboard: services.clipboard)
        case .focus:
            FocusModuleView(focus: services.focus)
        case .ramCleaner:
            MemoryCleanerModuleView(cleaner: services.memoryCleaner,
                                    system: services.system,
                                    privilege: services.purgePrivilege)
        default:
            FeatureChecklistView(module: viewModel.activeModule)
        }
    }
}

// MARK: - AI Coding (gorgeous agent activity logs + approval interface)

private struct AICodingModuleView: View {
    @ObservedObject var aiCoding: AICodingService

    var body: some View {
        if let approval = aiCoding.pendingApproval {
            approvalView(approval)
        } else {
            statusAndHistoryView
        }
    }

    private func approvalView(_ log: AICodingService.LogEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .shadow(color: .orange.opacity(0.5), radius: 2)
                    Text("PENDING APPROVAL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Text("\(log.agent) needs attention in \(log.project)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let approvalError = aiCoding.approvalError {
                    Text(approvalError)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    aiCoding.handleApproval(approved: false)
                } label: {
                    Text("Deny")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button {
                    aiCoding.handleApproval(approved: true)
                } label: {
                    Text("Allow")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 4)
    }

    private var statusAndHistoryView: some View {
        HStack(spacing: 12) {
            // Live Status Tile
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.5), radius: 2)
                    Text(aiCoding.status.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(statusColor)
                }
                if aiCoding.status == .idle {
                    Text("All agents inactive")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                } else {
                    Text("\(aiCoding.activeAgent) · \(aiCoding.activeProject)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .leading)

            Divider().overlay(Color.white.opacity(0.08))

            // Limits & Logs unified carousel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Ollama status
                    MiniLimitTile(
                        title: "Ollama",
                        valueStr: aiCoding.isOllamaRunning ? (aiCoding.ollamaModels.first ?? "Running") : "Offline",
                        icon: "cpu",
                        iconColor: .green,
                        statusDot: aiCoding.isOllamaRunning ? .green : .gray
                    )

                    // Cloud API Spend
                    MiniLimitTile(
                        title: aiCoding.cloudProvider,
                        valueStr: cloudValue,
                        icon: "cloud.fill",
                        iconColor: .cyan,
                        ratio: cloudRatio
                    )

                    // Claude Code
                    MiniLimitTile(
                        title: "Claude Code",
                        valueStr: claudeValue,
                        icon: "terminal.fill",
                        iconColor: .purple,
                        ratio: claudeRatio
                    )

                    // Antigravity
                    MiniLimitTile(
                        title: "Antigravity",
                        valueStr: antigravityValue,
                        icon: "sparkles",
                        iconColor: .orange,
                        ratio: antigravityRatio
                    )

                    if !aiCoding.recentLogs.isEmpty {
                        Divider()
                            .overlay(Color.white.opacity(0.12))
                            .frame(maxHeight: 28)

                        ForEach(aiCoding.recentLogs) { log in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(log.agent)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(RelativeTime.ago(log.timestamp))
                                        .font(.system(size: 8))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                                Text(log.project)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.purple.opacity(0.8))
                                    .lineLimit(1)
                                Text(log.message)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            .padding(4)
                            .frame(width: 110, height: 38, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                        }
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch aiCoding.status {
        case .idle: return .gray
        case .running: return .green
        case .needsAttention: return .orange
        case .completed: return .purple
        }
    }

    // Budget tiles show real numbers when `ai_limits.json` is present, otherwise
    // an honest "No data" with no progress bar.
    private var cloudValue: String {
        guard let used = aiCoding.cloudBudgetUsed, let limit = aiCoding.cloudBudgetLimit else { return "No data" }
        return "$\(String(format: "%.2f", used)) / $\(String(format: "%.2f", limit))"
    }

    private var cloudRatio: Double? {
        guard let used = aiCoding.cloudBudgetUsed, let limit = aiCoding.cloudBudgetLimit, limit > 0 else { return nil }
        return used / limit
    }

    private var claudeValue: String {
        guard let used = aiCoding.claudeCodeUsed, let limit = aiCoding.claudeCodeLimit else { return "No data" }
        return "\(used) / \(limit) reqs"
    }

    private var claudeRatio: Double? {
        guard let used = aiCoding.claudeCodeUsed, let limit = aiCoding.claudeCodeLimit, limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }

    private var antigravityValue: String {
        guard let used = aiCoding.antigravityUsed, let limit = aiCoding.antigravityLimit else { return "No data" }
        return "\(used / 1000)k / \(limit / 1000)k tok"
    }

    private var antigravityRatio: Double? {
        guard let used = aiCoding.antigravityUsed, let limit = aiCoding.antigravityLimit, limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }
}

// MARK: - Mini Limit Tile

private struct MiniLimitTile: View {
    let title: String
    let valueStr: String
    let icon: String
    let iconColor: Color
    var ratio: Double? = nil
    var statusDot: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                if let statusDot = statusDot {
                    Circle()
                        .fill(statusDot)
                        .frame(width: 5, height: 5)
                        .shadow(color: statusDot.opacity(0.5), radius: 1)
                }
            }

            Text(valueStr)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let ratio = ratio {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.12))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(progressBarColor(ratio))
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(ratio))))
                    }
                }
                .frame(height: 2)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(5)
        .frame(width: 116, height: 38, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(glowColor(ratio), lineWidth: ratio != nil && ratio! >= 0.8 ? 1 : 0)
        )
    }

    private func progressBarColor(_ r: Double) -> Color {
        if r >= 1.0 { return .red }
        if r >= 0.8 { return .orange }
        return .blue
    }

    private func glowColor(_ r: Double?) -> Color {
        guard let r = r else { return .clear }
        if r >= 1.0 { return .red.opacity(0.4) }
        if r >= 0.8 { return .orange.opacity(0.3) }
        return .clear
    }
}

// MARK: - Dashboard (glanceable real tiles)

private struct DashboardModuleView: View {
    @ObservedObject var services: ServiceHub

    var body: some View {
        HStack(spacing: 8) {
            StatTile(symbol: "clock", title: services.time.clock, subtitle: services.time.dateLabel)
            if services.battery.hasBattery {
                StatTile(symbol: services.battery.symbol, title: "\(services.battery.percent)%", subtitle: batterySub)
            }
            StatTile(symbol: "cpu", title: "\(Int(services.system.cpuUsage * 100))%", subtitle: "CPU")
            StatTile(symbol: "memorychip", title: "\(Int(services.system.memoryUsage * 100))%", subtitle: "RAM")
        }
    }

    private var batterySub: String {
        if services.battery.isCharging { return "Charging" }
        if let m = services.battery.minutesRemaining { return "\(m / 60)h \(m % 60)m" }
        return "Battery"
    }
}

// MARK: - Media (real now-playing + transport)

private struct MediaModuleView: View {
    @ObservedObject var media: MediaService

    var body: some View {
        if let np = media.nowPlaying {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(np.artist.isEmpty ? np.app.rawValue : np.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    TransportButton(symbol: "backward.fill") { media.previous() }
                    TransportButton(symbol: np.isPlaying ? "pause.fill" : "play.fill") { media.playPause() }
                    TransportButton(symbol: "forward.fill") { media.next() }
                }
            }
            .foregroundStyle(.white)
        } else {
            EmptyHint(symbol: "play.slash", text: "Play something in Music or Spotify.")
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar (real EventKit)

private struct CalendarModuleView: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        switch calendar.access {
        case .denied:
            EmptyHint(symbol: "calendar.badge.exclamationmark", text: "Enable Calendar access in System Settings ▸ Privacy.")
        case .unknown:
            EmptyHint(symbol: "calendar", text: "Requesting calendar access…")
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    }
                }
            }
        }
    }
}

// MARK: - Focus (Do Not Disturb toggle)

private struct FocusModuleView: View {
    @ObservedObject var focus: FocusService

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                focus.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.fill")
                    Text(focus.isOn ? "Turn Off" : "Turn On")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focus.isOn ? .black : .white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    Capsule().fill(focus.isOn ? Color.purple.opacity(0.9) : Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }
        .onAppear { focus.refreshAccessibility() }
    }

    private var statusTitle: String {
        if !focus.accessibilityGranted { return "Accessibility permission needed" }
        return focus.isOn ? "Do Not Disturb is on" : "Do Not Disturb is off"
    }

    private var statusSubtitle: String {
        if !focus.accessibilityGranted || focus.lastToggleFailed {
            return "Enable NotchHub in System Settings ▸ Privacy ▸ Accessibility to toggle Focus."
        }
        return "Silences notifications across your Mac."
    }
}

// MARK: - RAM Cleaner (official purge + live memory breakdown)

private struct MemoryCleanerModuleView: View {
    @ObservedObject var cleaner: MemoryCleanerService
    @ObservedObject var system: SystemMonitorService
    @ObservedObject var privilege: PurgePrivilege

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if cleaner.state != .cleaning { permissionControl }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * cleaner.pressure))
                    }
                }
                .frame(height: 5)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            cleanButton
        }
        .onAppear {
            cleaner.refresh()
            privilege.refresh()
        }
        .onChange(of: system.memoryUsage) { cleaner.refresh() }
    }

    /// One-time "Always Allow" affordance: enable passwordless cleaning, or show
    /// it's on (tap to revoke). Sits on the title row so the 46pt card height is
    /// unchanged.
    @ViewBuilder private var permissionControl: some View {
        if privilege.isPasswordless {
            Button { privilege.disableAlwaysAllow() } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Passwordless cleaning is on — tap to revoke (asks for admin once).")
        } else {
            Button { privilege.enableAlwaysAllow() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "key")
                    Text("Skip password")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Authenticate once so future cleans don't ask for a password.")
        }
    }

    private var barColor: Color {
        if cleaner.pressure > 0.85 { return .red }
        if cleaner.pressure > 0.7 { return .orange }
        return .green
    }

    private var cleanButton: some View {
        Button {
            cleaner.clean()
        } label: {
            HStack(spacing: 6) {
                if cleaner.state == .cleaning {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let icon = buttonIcon {
                    Image(systemName: icon)
                }
                Text(buttonText)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(buttonForeground)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(buttonFill))
        }
        .buttonStyle(.plain)
        .disabled(cleaner.state == .cleaning)
    }

    /// "Freed 2.8 GB" / "Freed 320 MB" / "Already optimized".
    private var freedLabel: String {
        guard let mb = cleaner.lastFreedMB else { return "Already optimized" }
        return mb >= 1024 ? String(format: "Freed %.1f GB", mb / 1024)
            : "Freed \(Int(mb.rounded())) MB"
    }

    private var statusTitle: String {
        switch cleaner.state {
        case .idle: return "Memory"
        case .cleaning: return "Freeing inactive memory…"
        case .done: return freedLabel
        case .cancelled: return "Cancelled"
        case .needsPermission: return "Needs permission"
        case .failed: return "Couldn't free memory"
        }
    }

    /// The breakdown line; when a clean just finished, show the real
    /// Activity-Monitor "Memory Used" reduction instead.
    private var subtitle: String {
        switch cleaner.state {
        case .needsPermission:
            return "Authenticate (Touch ID or password) to flush cached memory."
        case .done where cleaner.lastUsedBeforeGB - cleaner.lastUsedAfterGB >= 0.05:
            return String(format: "Memory used %.1f → %.1f GB",
                          cleaner.lastUsedBeforeGB, cleaner.lastUsedAfterGB)
        default:
            return String(format: "App %.1f · Cached %.1f · Compressed %.1f · Swap %.1f GB",
                          cleaner.appGB, cleaner.cachedGB, cleaner.compressedGB, cleaner.swapUsedGB)
        }
    }

    private var buttonText: String {
        switch cleaner.state {
        case .idle: return "Free Up RAM"
        case .cleaning: return "Cleaning"
        case .done: return freedLabel
        case .cancelled: return "Cancelled"
        case .needsPermission: return "Needs permission"
        case .failed: return "Try again"
        }
    }

    private var buttonIcon: String? {
        switch cleaner.state {
        case .idle: return "memorychip"
        case .done: return "checkmark"
        case .needsPermission: return "lock.fill"
        case .cancelled, .failed: return "arrow.clockwise"
        case .cleaning: return nil
        }
    }

    private var buttonForeground: Color {
        switch cleaner.state {
        case .idle, .done: return .black
        default: return .white
        }
    }

    private var buttonFill: Color {
        switch cleaner.state {
        case .idle, .done: return .green
        case .needsPermission: return Color.orange.opacity(0.9)
        default: return Color.white.opacity(0.12)
        }
    }
}

// MARK: - Clipboard (recent text snippets)

private struct ClipboardModuleView: View {
    @ObservedObject var clipboard: ClipboardService

    var body: some View {
        HStack(spacing: 8) {
            if clipboard.clips.isEmpty {
                EmptyHint(symbol: "doc.on.clipboard", text: "Copy text, an image, or a file to collect it here.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(clipboard.clips) { clip in
                            Button {
                                clipboard.copy(clip)
                            } label: {
                                ClipTile(clip: clip, thumbnail: clipboard.thumbnails[clip.id])
                            }
                            .buttonStyle(.plain)
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
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }

    @ViewBuilder
    private var thumbView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.1))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: clip.symbol).font(.system(size: 14)))
        }
    }
}

// MARK: - Remaining modules (descriptive until implemented)

private struct FeatureChecklistView: View {
    let module: FeatureModule

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(module.items.prefix(8), id: \.self) { item in
                    StatTile(symbol: "checkmark.circle", title: item, subtitle: "Planned")
                        .frame(width: 116)
                }
            }
        }
    }
}

// MARK: - Shared tiles

private struct StatTile: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .topLeading)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }
}

private struct EmptyHint: View {
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

// MARK: - Time helpers

private enum RelativeTime {
    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// "now", "in 12m", "in 3h" — compact countdown for chips.
    static func short(to date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "in \(max(minutes, 1))m" }
        let hours = minutes / 60
        return "in \(hours)h"
    }

    /// "now", "2m ago", "3h ago" — compact elapsed time for past events.
    static func ago(_ date: Date) -> String {
        let delta = -date.timeIntervalSinceNow
        if delta < 60 { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
