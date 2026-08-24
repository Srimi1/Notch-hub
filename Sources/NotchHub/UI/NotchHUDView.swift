import AppKit
import SwiftUI

/// The transient popup tier — the "medium black box" that grows out of the
/// notch when something lands on the pasteboard, then slides away.
struct NotchHUDView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var battery: BatteryService

    var body: some View {
        Group {
            switch viewModel.hudContent {
            case .clip(let clip):
                CopyHUDRow(clip: clip, thumbnail: clipboard.thumbnails[clip.id])
            case .peek:
                PeekRow(
                    clips: Array(clipboard.clips.prefix(3)),
                    thumbnails: clipboard.thumbnails
                ) { viewModel.restoreFromPeek($0) }
            case .charging:
                ChargingRow(battery: battery)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, NotchTheme.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.expandFromHUD() }
        .onHover { viewModel.setHudHover($0) }
    }
}

/// One copied item: icon, name, the little bit of file information the user
/// asked for, and nothing else.
private struct CopyHUDRow: View {
    let clip: ClipboardService.Clip
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 44, height: 44)
                .draggableFile(clip)

            VStack(alignment: .leading, spacing: 3) {
                Text(details.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = details.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Copied")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(NotchTheme.subtleSurface))
        }
        // Grows out of the notch; leaves by sliding down through the pill's
        // bottom edge, which the window mask clips — the "swallowed" dismissal.
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        ))
    }

    private var details: HudClipDetails {
        HudClipDetails.make(for: clip)
    }

    @ViewBuilder
    private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if case .file(let url) = clip.kind {
            // NSWorkspace answers synchronously, so the popup never waits on
            // the QuickLook thumbnail that will replace this a beat later.
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: clip.symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// The charge moment: the green glyph carries it, the text says how long.
private struct ChargingRow: View {
    @ObservedObject var battery: BatteryService

    var body: some View {
        HStack(spacing: 12) {
            BatteryGlyphView(
                level: battery.level,
                state: .charging,
                height: 20
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("Charging")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.secondaryText)
            }
            Spacer()
            Text("\(battery.percent)%")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .contentTransition(.numericText())
        }
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        ))
    }

    private var detail: String {
        guard let minutes = battery.minutesRemaining else { return "Power connected" }
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours) h \(rest) m until full" : "\(rest) m until full"
    }
}

/// The hover peek: the last few clips as small cards. Click one to put it back
/// on the pasteboard; keep hovering and the full dashboard takes over.
private struct PeekRow: View {
    let clips: [ClipboardService.Clip]
    let thumbnails: [UUID: NSImage]
    let onPick: (ClipboardService.Clip) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(clips) { clip in
                Button { onPick(clip) } label: {
                    HStack(spacing: 6) {
                        cardIcon(clip)
                            .frame(width: 22, height: 22)
                        Text(clip.preview)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(NotchTheme.subtleSurface))
                }
                .buttonStyle(.plain)
                .help("Copy again: \(clip.preview)")
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    @ViewBuilder
    private func cardIcon(_ clip: ClipboardService.Clip) -> some View {
        if let thumbnail = thumbnails[clip.id] {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: clip.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private extension View {
    /// File clips can be dragged straight out of the popup — into Finder, a
    /// mail draft, an upload dialog. Other clip kinds drag nothing.
    @ViewBuilder
    func draggableFile(_ clip: ClipboardService.Clip) -> some View {
        if case .file(let url) = clip.kind {
            onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            self
        }
    }
}
