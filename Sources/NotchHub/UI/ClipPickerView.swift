import AppKit
import SwiftUI

/// The clipboard history, dropped out of the notch by the global shortcut.
///
/// Built for the keyboard: the first nine rows carry a digit badge, so the
/// whole gesture is shortcut, digit, done — without the pointer ever moving.
/// Clicking works too.
struct ClipPickerView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var clipboard: ClipboardService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if clipboard.clips.isEmpty {
                empty
            } else {
                rows
            }
            footer
        }
        .padding(.horizontal, NotchTheme.horizontalPadding)
        // Clear the camera housing. The picker hangs from the top of the
        // screen, so eight points of padding put the first row — the one the
        // digit 1 selects — behind the notch itself.
        .padding(.top, viewModel.notchSize.height + 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.5))
            Text("Nothing copied yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
            Text("Copy something and press the shortcut again.")
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rows: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(Array(clipboard.clips.enumerated()), id: \.element.id) { index, clip in
                    Button {
                        viewModel.pickAndDismiss(clip)
                    } label: {
                        ClipPickerRow(
                            clip: clip,
                            thumbnail: clipboard.thumbnails[clip.id],
                            shortcut: index < 9 ? String(index + 1) : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("1–9 to paste · esc to close")
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.secondaryText)
            Spacer()
            if let hint = viewModel.pasteHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(1)
            }
        }
    }
}

/// One row: how to pick it, what it is, and when it was copied.
private struct ClipPickerRow: View {
    let clip: ClipboardService.Clip
    let thumbnail: NSImage?
    let shortcut: String?

    var body: some View {
        HStack(spacing: 10) {
            badge
            icon
                .frame(width: 24, height: 24)
            Text(clip.preview)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(RelativeTime.ago(clip.date))
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(NotchTheme.subtleSurface))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var badge: some View {
        if let shortcut {
            Text(shortcut)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let thumbnail {
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
