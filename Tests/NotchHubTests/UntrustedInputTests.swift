import EventKit
import Foundation
import Testing
@testable import NotchHub

/// Calendar and reminder text arrives from other applications and is rendered in
/// an always-on-top overlay, so it is treated as hostile input.
@Suite("Untrusted display text")
struct DisplaySanitizerTests {

    @Test
    func stripsBidiOverridesAndIsolates() {
        // "Standup\u{202E}gnp.exe" — the override reverses everything after it,
        // which is the classic filename/label spoof.
        let spoofed = "Standup\u{202E}gnp.exe"
        #expect(DisplaySanitizer.text(spoofed, limit: 120) == "Standupgnp.exe")

        for scalar: UInt32 in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068,
                               0x2069, 0x200E, 0x200F, 0x061C] {
            guard let unicodeScalar = Unicode.Scalar(scalar) else { continue }
            #expect(DisplaySanitizer.isDisallowed(unicodeScalar), "U+\(String(scalar, radix: 16))")
        }
    }

    @Test
    func stripsInvisibleAndDefaultIgnorableCharacters() {
        // Hangul fillers render as blank but are *not* Cf, so a naive
        // control-character filter lets them through.
        #expect(DisplaySanitizer.text("Pay\u{3164}Rent", limit: 120) == "PayRent")
        #expect(DisplaySanitizer.text("A\u{115F}\u{1160}\u{FFA0}B", limit: 120) == "AB")
        #expect(DisplaySanitizer.text("soft\u{00AD}hyphen", limit: 120) == "softhyphen")
        #expect(DisplaySanitizer.text("zero\u{200B}width", limit: 120) == "zerowidth")
        #expect(DisplaySanitizer.text("bom\u{FEFF}", limit: 120) == "bom")
        #expect(DisplaySanitizer.text("tag\u{E0041}", limit: 120) == "tag")

        // Non-characters cannot be written as string literals, so build them.
        let nonCharacters = String(String.UnicodeScalarView(
            [0xFDD0, 0xFFFE, 0x1FFFE].compactMap { Unicode.Scalar($0 as UInt32) }
        ))
        #expect(DisplaySanitizer.text("nonchar" + nonCharacters, limit: 120) == "nonchar")
    }

    @Test
    func keepsEmojiJoinersSoOrdinaryTitlesStillRender() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} School run"
        #expect(DisplaySanitizer.text(family, limit: 120) == family)
        #expect(DisplaySanitizer.text("check \u{2714}\u{FE0F}", limit: 120) == "check \u{2714}\u{FE0F}")
    }

    @Test
    func clampsCombiningMarkStacksSoTitlesCannotPaintOutsideTheNotch() {
        let zalgo = "H" + String(repeating: "\u{0301}", count: 60) + "i"
        let cleaned = DisplaySanitizer.text(zalgo, limit: 120)
        #expect(cleaned == "H\u{0301}\u{0301}i")
    }

    @Test
    func collapsesWhitespaceAndEnforcesTheLimit() {
        #expect(DisplaySanitizer.text("  a \n\t b  ", limit: 120) == "a b")
        #expect(DisplaySanitizer.text("abcdef", limit: 3) == "abc")
        #expect(DisplaySanitizer.text(nil, limit: 10).isEmpty)
        #expect(DisplaySanitizer.text("abc", limit: 0).isEmpty)
    }
}

/// A crafted invite must not be able to make NotchHub open a router admin page,
/// a link-local metadata endpoint, or anything else off the public internet.
@Suite("Safe external URLs")
struct SafeExternalURLTests {

    @Test
    func acceptsOrdinaryPublicMeetingLinks() {
        #expect(SafeExternalURL.meetingURL(URL(string: "https://meet.google.com/abc-defg")) != nil)
        #expect(SafeExternalURL.meetingURL(URL(string: "https://example.co.uk/room/1")) != nil)
        #expect(SafeExternalURL.meetingURL(URL(string: "zoommtg://zoom.us/join?confno=1")) != nil)
    }

    @Test
    func rejectsNonHTTPSAndCredentialBearingURLs() {
        #expect(SafeExternalURL.meetingURL(URL(string: "http://example.com/room")) == nil)
        #expect(SafeExternalURL.meetingURL(URL(string: "file:///etc/passwd")) == nil)
        #expect(SafeExternalURL.meetingURL(URL(string: "javascript:alert(1)")) == nil)
        #expect(SafeExternalURL.meetingURL(URL(string: "https://user:pw@example.com/")) == nil)
        #expect(SafeExternalURL.meetingURL(URL(string: "evilapp://open")) == nil)
        #expect(SafeExternalURL.meetingURL(nil) == nil)
    }

    @Test
    func rejectsLoopbackPrivateAndLinkLocalHosts() {
        let blocked = [
            "localhost", "localhost.", "LOCALHOST", "app.localhost",
            "printer.local", "vault.internal", "router.home.arpa", "box.lan",
            "127.0.0.1", "127.1.2.3", "10.0.0.5", "192.168.1.1", "172.16.9.9",
            "172.31.255.255", "169.254.169.254", "100.64.0.1", "0.0.0.0",
            "255.255.255.255", "224.0.0.1", "198.51.100.7", "example.test"
        ]
        for host in blocked {
            #expect(
                SafeExternalURL.meetingURL(URL(string: "https://\(host)/x")) == nil,
                "expected \(host) to be refused"
            )
        }
    }

    /// `inet_pton` rejects octal/hex/dword forms, but the URL loader still
    /// resolves them — so anything that merely *looks* numeric is refused too.
    @Test
    func rejectsAlternateNumericSpellingsOfLoopback() {
        for host in ["0177.0.0.1", "2130706433", "0x7f000001", "127.1", "0.0.0.0.0"] {
            #expect(
                SafeExternalURL.meetingURL(URL(string: "https://\(host)/x")) == nil,
                "expected \(host) to be refused"
            )
        }
    }

    @Test
    func rejectsPrivateAndMappedIPv6Literals() {
        let blocked = [
            "[::1]", "[::]", "[fe80::1]", "[fc00::1]", "[fd12:3456::1]",
            "[ff02::1]", "[2001:db8::1]", "[::ffff:127.0.0.1]", "[::ffff:10.0.0.1]"
        ]
        for host in blocked {
            #expect(
                SafeExternalURL.meetingURL(URL(string: "https://\(host)/x")) == nil,
                "expected \(host) to be refused"
            )
        }
        #expect(SafeExternalURL.meetingURL(URL(string: "https://[2606:4700::1111]/x")) != nil)
    }

    @Test
    func mapsLinksAreSanitizedAndBounded() throws {
        let url = try #require(SafeExternalURL.mapsURL(for: "1 Infinite\u{202E} Loop"))
        #expect(url.scheme == "https")
        #expect(url.host == "maps.apple.com")
        // The bidi override is gone rather than percent-encoded into the query.
        #expect(!url.absoluteString.contains("%E2%80%AE"))
        #expect(SafeExternalURL.mapsURL(for: "   ") == nil)
        #expect(SafeExternalURL.mapsURL(for: "\u{200B}") == nil)
        #expect(SafeExternalURL.mapsURL(for: String(repeating: "x", count: 301)) == nil)
    }
}

/// macOS posts no notification when the user changes an app's Calendar or
/// Reminders switch, so the status is re-read and mapped through this decision.
@Suite("EventKit access decisions")
struct EventKitAccessDecisionTests {

    @Test
    func writeOnlyAndRestrictedCountAsDenied() {
        #expect(EventKitAccessDecision.decide(for: .fullAccess) == .granted)
        #expect(EventKitAccessDecision.decide(for: .notDetermined) == .needsPrompt)
        #expect(EventKitAccessDecision.decide(for: .denied) == .denied)
        #expect(EventKitAccessDecision.decide(for: .restricted) == .denied)
        // Write-only can add items but cannot read them, so every listing
        // feature is unavailable and must say so rather than showing nothing.
        #expect(EventKitAccessDecision.decide(for: .writeOnly) == .denied)
    }
}

@Suite("Completion tombstones")
struct CompletionTombstoneTests {

    @Test
    func suppressOnlyFetchesThatPredateTheCompletion() {
        var tombstones = CompletionTombstones()
        // Reload 4 was in flight when "a" was completed.
        tombstones.insert("a", generation: 4)
        #expect(tombstones.count == 1)

        // Reload 4's snapshot still lists "a": it predates the write.
        #expect(tombstones.suppresses("a", forGeneration: 4))
        // An earlier straggler is even more stale.
        #expect(tombstones.suppresses("a", forGeneration: 3))
        // Reload 5 started after the write, so its answer is authoritative.
        #expect(!tombstones.suppresses("a", forGeneration: 5))
        #expect(!tombstones.suppresses("unknown", forGeneration: 1))
    }

    @Test
    func pruningKeepsUnresolvedCompletionsAndDropsResolvedOnes() {
        var tombstones = CompletionTombstones()
        tombstones.insert("resolved", generation: 4)
        tombstones.insert("inflight", generation: 6)

        tombstones.pruneResolved(upTo: 6)

        #expect(tombstones.count == 1)
        #expect(!tombstones.suppresses("resolved", forGeneration: 4))
        #expect(tombstones.suppresses("inflight", forGeneration: 6))
    }

    @Test
    func isHardCappedSoFailingReloadsCannotGrowItForever() {
        var tombstones = CompletionTombstones(limit: 3)
        for index in 0 ..< 10 { tombstones.insert("id-\(index)", generation: index) }
        #expect(tombstones.count == 3)
        #expect(!tombstones.suppresses("id-0", forGeneration: 0))
        #expect(tombstones.suppresses("id-9", forGeneration: 9))
    }
}
