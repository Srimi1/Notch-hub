import SwiftUI

/// The first-run permission pass.
///
/// macOS will not let an app grant itself Accessibility, Automation, or Full
/// Disk Access, so the closest thing to "everything on by default" is to ask
/// for all of it once, up front, where the user can see what each one buys.
/// The alternative — the old behavior — was each feature failing quietly the
/// first time it was touched, which reads as a broken app rather than a
/// missing switch.
struct OnboardingView: View {

    @Bindable var permissions: PermissionCenter
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 460)
        .task { await permissions.refreshAll() }
        // The switches live in System Settings, and macOS posts nothing when
        // they change — so re-read every time the user comes back.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await permissions.refreshAll() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up NotchHub")
                .font(.system(size: 19, weight: .semibold))
            Text("NotchHub needs a few permissions from macOS. Grant them now and "
                + "every module works from the start — or skip and turn them on later "
                + "from Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(PermissionCenter.Permission.allCases) { permission in
                    PermissionRowView(
                        permission: permission,
                        status: permissions.status(of: permission)
                    ) {
                        permissions.request(permission)
                    }
                }
            }
            .padding(20)
        }
    }

    private var footer: some View {
        HStack {
            Text(remainingSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Grant All…") { grantAll() }
            Button("Done") { onFinish() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var remainingSummary: String {
        let outstanding = permissions.outstanding.count
        if outstanding == 0 { return "All set." }
        return "\(outstanding) still to grant. NotchHub works without them — those features just stay quiet."
    }

    /// Fires every prompt that still has one. Deliberately sequential-ish: the
    /// system queues its own dialogs, and the panes open on top of each other
    /// otherwise.
    private func grantAll() {
        for permission in permissions.outstanding where permission.isPromptable {
            permissions.request(permission)
        }
    }
}
