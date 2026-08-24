import AppKit
import SwiftUI

/// The transient popup tier — the "medium black box" that grows out of the
/// notch when something lands on the pasteboard, then slides away.
struct NotchHUDView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var clipboard: ClipboardService

    var body: some View {
        Group {
            switch viewModel.hudContent {
            case .clip(let clip):
                CopyHUDRow(clip: clip, thumbnail: clipboard.thumbnails[clip.id])
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
