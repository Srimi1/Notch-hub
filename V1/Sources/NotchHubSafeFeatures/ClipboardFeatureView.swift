import SwiftUI

public struct ClipboardFeatureView: View {
    private let model: ClipboardHistoryModel

    public init(model: ClipboardHistoryModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            captureControl
            if !model.isEnabled {
                SafeEmptyState(
                    symbol: "clipboard.badge.questionmark",
                    title: "Clipboard history is off",
                    message: "Turn it on to remember text copied after you enable it. Nothing is read while it is off."
                )
            } else {
                enabledContent
            }
            privacyFooter
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard history")
    }

    @ViewBuilder
    private var enabledContent: some View {
        if let issue = model.lastIssue {
            SafeIssueBanner(message: issue.message, actionTitle: "Dismiss", action: model.dismissIssue)
        }
        if model.entries.isEmpty {
            SafeEmptyState(
                symbol: "clipboard",
                title: "Clipboard history is empty",
                message: "Copy text to keep a short, in-memory history. Recognized protected items are ignored."
            )
        } else {
            entryList
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent text").font(.headline)
                Text("\(model.entries.count) of \(ClipboardHistoryModel.defaultHistoryLimit) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear", action: model.clear)
                .buttonStyle(.bordered)
                .disabled(model.entries.isEmpty)
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(model.entries) { entry in
                    ClipboardEntryRow(entry: entry) {
                        await model.restore(entry)
                    }
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private var captureControl: some View {
        Toggle(isOn: captureBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember copied text").font(.subheadline.weight(.semibold))
                Text(model.isEnabled ? "On — new text may be retained" : "Off — clipboard is not read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var captureBinding: Binding<Bool> {
        Binding(
            get: { model.isEnabled },
            set: { enabled in
                if enabled {
                    Task { await model.enable() }
                } else {
                    model.disable()
                }
            }
        )
    }

    private var privacyFooter: some View {
        Label(
            "Opt-in history stays in memory and clears when switched off or NotchHub quits",
            systemImage: "lock.shield"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let restore: @MainActor () async -> Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(.subheadline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.copiedAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { _ = await restore() }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy this item")
            .accessibilityLabel("Copy \(entry.preview)")
        }
        .padding(9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
