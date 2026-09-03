import SwiftUI

struct CapabilityFoundationView: View {
    let capability: AppCapability
    let edition: ApplicationEdition

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: capability.systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.cyan)
            Text(capability.title).font(.title3.weight(.semibold))
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var description: String {
        switch (edition, capability) {
        case (.lite, .dashboard): "A sandbox-safe system summary for the Store edition."
        case (.lite, .clipboard): "Standard pasteboard tools without external automation."
        case (.lite, .focus): "Local focus timers with no cache-cleanup access."
        default: "The V1 shell is ready for the audited \(capability.title) module."
        }
    }
}

struct UsageRing: View {
    let value: Double?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            if let value {
                Circle()
                    .trim(from: 0, to: value / 100)
                    .stroke(
                        utilizationColor(value),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: diameter * 0.35, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Usage")
        .accessibilityValue(value.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
    }
}

func utilizationColor(_ value: Double) -> Color {
    switch value {
    case 100...: .red
    case 80...: .orange
    default: .cyan
    }
}
