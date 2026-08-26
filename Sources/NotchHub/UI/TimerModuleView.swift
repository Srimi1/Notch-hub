import SwiftUI

struct TimerModuleView: View {
    @Bindable var timers: ActivityTimerService

    var body: some View {
        HStack(spacing: 10) {
            quickTimers
            Divider().overlay(Color.white.opacity(0.12))
            if timers.timers.isEmpty {
                timerHint
            } else {
                activeTimerContent
            }
        }
    }

    private var quickTimers: some View {
        HStack(spacing: 6) {
            ForEach([5, 15, 25, 45], id: \.self) { minutes in
                Button("\(minutes)m") {
                    timers.create(title: minutes == 25 ? "Focus" : "Timer", duration: Double(minutes * 60))
                }
                .buttonStyle(NotchButtonStyle(shape: .bare))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 28)
                .background(Capsule().fill(Color.orange.opacity(0.28)))
                .accessibilityLabel("Start a \(minutes) minute timer")
            }
        }
    }

    private var activeTimers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(timers.timers) { timer in
                    TimerTile(timer: timer, now: timers.currentDate, service: timers)
                }
            }
        }
    }

    private var activeTimerContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = timers.lastError {
                ModuleErrorBanner(message: error, clear: timers.clearError)
            }
            activeTimers
        }
    }

    private var timerHint: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timers.lastError ?? "Start a timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(timers.lastError == nil ? .white : .red)
            Text("Timers survive sleep and relaunch.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct TimerTile: View {
    let timer: ActivityTimerRecord
    let now: Date
    let service: ActivityTimerService

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            }
            Button { primaryAction() } label: {
                Image(systemName: primarySymbol)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NotchButtonStyle(shape: .circle))
            .accessibilityLabel(primaryLabel)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: 125, height: 38)
        .background(RoundedRectangle(cornerRadius: NotchTheme.cardRadius).fill(Color.white.opacity(0.07)))
    }

    private var statusText: String {
        switch timer.status {
        case .completed: "Complete"
        case .paused: "Paused"
        case .running:
            RelativeTime.timer(timer.remaining(at: now))
        }
    }

    private var primarySymbol: String {
        switch timer.status {
        case .completed: "checkmark"
        case .paused: "play.fill"
        case .running: "pause.fill"
        }
    }

    private var primaryLabel: String {
        switch timer.status {
        case .completed: "Dismiss timer"
        case .paused: "Resume timer"
        case .running: "Pause timer"
        }
    }

    private func primaryAction() {
        switch timer.status {
        case .completed: service.dismiss(id: timer.id)
        case .paused: service.resume(id: timer.id)
        case .running: service.pause(id: timer.id)
        }
    }
}

struct ReminderModuleView: View {
    @Bindable var reminders: ReminderService

    var body: some View {
        switch reminders.access {
        case .unknown:
            permissionPrompt
        case .denied:
            statusHint("Enable Reminders in System Settings ▸ Privacy.", isError: true)
        case .granted where reminders.reminders.isEmpty:
            statusHint(reminders.lastError ?? "No incomplete reminders are due soon.", isError: reminders.lastError != nil)
        case .granted:
            reminderContent
        }
    }

    private var permissionPrompt: some View {
        HStack(spacing: 10) {
            statusHint("Allow access to surface due reminders.", isError: false)
            Button("Enable Reminders") {
                Task { @MainActor in await reminders.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var reminderList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(reminders.reminders.prefix(8)) { reminder in
                    Button {
                        Task { @MainActor in await reminders.complete(id: reminder.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                            Text(reminder.dueDate.map(RelativeTime.clock) ?? "No due date")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(width: 130, height: 34, alignment: .leading)
                    }
                    .buttonStyle(NotchButtonStyle(shape: .card))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Complete \(reminder.title)")
                }
            }
        }
    }

    private var reminderContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = reminders.lastError {
                ModuleErrorBanner(message: error, clear: reminders.clearError)
            }
            reminderList
        }
    }

    private func statusHint(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
            Text(text).lineLimit(2)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(isError ? .red : .white.opacity(0.7))
    }
}

private struct ModuleErrorBanner: View {
    let message: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(2)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(NotchButtonStyle(shape: .bare))
            .accessibilityLabel("Dismiss error")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.red)
    }
}
