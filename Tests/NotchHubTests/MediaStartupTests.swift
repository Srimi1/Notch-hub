import Foundation
import Testing
@testable import NotchHub

/// The two halves of Media start at different moments on purpose: one asks macOS
/// for nothing and can run from launch, the other raises an Automation prompt the
/// first time it touches a running player.
@Suite("Media startup split")
@MainActor
struct MediaStartupTests {

    /// The service plus the pieces a test needs to see inside it.
    private struct Rig {
        var service: MediaService
        var launcher: FakeLauncher
        var scripted: AppleScriptMediaSource
        var adapter: MediaRemoteAdapterSource
    }

    private func makeRig() -> Rig {
        let launcher = FakeLauncher()
        let adapter = MediaRemoteAdapterSource(
            launcher: launcher,
            schedule: { _, work in work() },
            resolveApp: { bundleId, _ in MediaApp(name: "Test Player", bundleId: bundleId) }
        )
        let scripted = AppleScriptMediaSource()
        return Rig(
            service: MediaService(appleScript: scripted, adapter: adapter),
            launcher: launcher,
            scripted: scripted,
            adapter: adapter
        )
    }

    /// The whole point of the split: a track can reach the collapsed notch
    /// without the user having opened anything, and without a prompt.
    @Test
    func systemPlaybackStartsWithoutTouchingAppleEvents() async {
        let rig = makeRig()

        rig.service.startSystemPlayback()
        await Task.yield()

        #expect(rig.adapter.isStreaming)
        #expect(rig.launcher.state.launches.count == 1)
        #expect(rig.scripted.isPolling == false)
        rig.service.stop()
    }

    /// The prompting half only runs when asked for by name.
    @Test
    func scriptedPlayersStartSeparately() async {
        let rig = makeRig()

        rig.service.startScriptedPlayers()
        await Task.yield()

        #expect(rig.scripted.isPolling)
        rig.service.stop()
    }

    @Test
    func startRunsBothAndIsIdempotent() async {
        let rig = makeRig()

        rig.service.startSystemPlayback()
        rig.service.start()
        await Task.yield()

        #expect(rig.adapter.isStreaming)
        #expect(rig.scripted.isPolling)
        // Starting the adapter twice must not spawn a second process.
        #expect(rig.launcher.state.launches.count == 1)
        rig.service.stop()
    }

    @Test
    func stoppingStopsBothHalves() async {
        let rig = makeRig()

        rig.service.start()
        await Task.yield()
        rig.service.stop()
        await Task.yield()

        #expect(rig.scripted.isPolling == false)
        #expect(rig.adapter.isStreaming == false)
        #expect(rig.service.nowPlaying == nil)
    }
}
