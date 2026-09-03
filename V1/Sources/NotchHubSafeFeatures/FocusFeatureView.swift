import SwiftUI

public struct FocusFeatureView: View {
    private let model: FocusTimerModel

    public init(model: FocusTimerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 16) {
            header
            if let issue = model.lastIssue {
                SafeIssueBanner(message: issue.message, actionTitle: nil, action: nil)
            }
            timerFace
            durationChoices
            controls
            Spacer(minLength: 0)
            Label("A local timer—no Accessibility access or system Focus changes", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus timer")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Focus session").font(.headline)
                Text(model.state.title).font(.caption).foregroundStyle(statusColor)
            }
            Spacer()
            if model.completedSessionCount > 0 {
                Label("\(model.completedSessionCount)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(model.completedSessionCount) completed sessions")
            }
        }
    }

    private var timerFace: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(model.clockLabel)
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 148, height: 148)
            if model.state == .completed {
                Label("Session complete", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private var durationChoices: some View {
        HStack(spacing: 8) {
            ForEach([15, 25, 50], id: \.self) { minutes in
                Button("\(minutes) min") {
                    model.setDuration(minutes: minutes)
                }
                .buttonStyle(.bordered)
                .tint(model.selectedMinutes == minutes ? .cyan : nil)
                .disabled(model.state == .running)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session duration")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(primaryActionTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .keyboardShortcut(.space, modifiers: [])
            Button("Reset", action: model.reset)
                .buttonStyle(.bordered)
                .disabled(model.state == .idle && model.progress == 0)
        }
    }

    private var primaryActionTitle: String {
        switch model.state {
        case .running: "Pause"
        case .paused: "Resume"
        case .completed: "Start again"
        case .idle: "Start"
        }
    }

    private func primaryAction() {
        if model.state == .running {
            model.pause()
        } else {
            model.start()
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .completed: .green
        case .running: .cyan
        case .idle, .paused: .secondary
        }
    }
}
