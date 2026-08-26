import Darwin
import Foundation

/// Normalisation for text that arrives from *other* applications — calendar
/// titles, event locations, reminder titles, timer labels.
///
/// This text is rendered in an always-on-top overlay the user cannot easily
/// inspect, so anything that can reorder, hide, or visually spoof characters is
/// removed before it is displayed:
///
/// * C0/C1 controls and Unicode `Cf` format characters (this covers the bidi
///   overrides `U+202A…U+202E` and the isolates `U+2066…U+2069`),
/// * every default-ignorable code point — notably the Hangul fillers
///   (`U+115F`, `U+1160`, `U+3164`, `U+FFA0`), which are *not* `Cf` yet render
///   as blank and are a classic label-spoofing vector,
/// * the Tags block (`U+E0000…U+E007F`) and the interlinear annotation marks,
/// * non-characters, and
/// * runaway combining-mark stacks, which would otherwise let a single title
///   paint outside the notch ("Zalgo" text).
enum DisplaySanitizer {

    /// Default-ignorable scalars that are kept: they *compose* emoji rather than
    /// hiding or reordering text, and stripping them would break rendering of
    /// ordinary titles like "👨‍👩‍👧 School run".
    private static let allowedInvisibles: Set<UInt32> = [
        0x200D, // ZERO WIDTH JOINER
        0xFE0E, // VARIATION SELECTOR-15 (text presentation)
        0xFE0F // VARIATION SELECTOR-16 (emoji presentation)
    ]

    /// At most this many combining marks may follow a single base character.
    private static let maximumCombiningRun = 2

    static func text(_ value: String?, limit: Int) -> String {
        guard let value else { return "" }

        var kept = String.UnicodeScalarView()
        var combiningRun = 0
        for scalar in value.unicodeScalars {
            guard !isDisallowed(scalar) else { continue }
            if isCombiningMark(scalar) {
                combiningRun += 1
                guard combiningRun <= maximumCombiningRun else { continue }
            } else {
                combiningRun = 0
            }
            kept.append(scalar)
        }

        let collapsed = String(kept)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(max(0, limit)))
    }

    /// True for scalars that can hide, reorder, or spoof rendered text.
    static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        if allowedInvisibles.contains(scalar.value) { return false }
        if CharacterSet.controlCharacters.contains(scalar) { return true }
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        if scalar.properties.generalCategory == .format { return true }
        return isReservedScalar(scalar.value)
    }

    private static func isReservedScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0xFDD0 ... 0xFDEF: return true // non-characters
        case 0xFFF9 ... 0xFFFB: return true // interlinear annotation
        case 0x1D173 ... 0x1D17A: return true // musical formatting controls
        case 0xE0000 ... 0xE007F: return true // Tags block
        default: return value & 0xFFFE == 0xFFFE // plane-end non-characters
        }
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: return true
        default: return false
        }
    }
}

/// Gate for URLs and locations that came from untrusted calendar data before
/// they are handed to `NSWorkspace.open`.
///
/// Only `https` (plus a small allowlist of meeting schemes) is permitted, and
/// the host must resolve to a *public* name or address: loopback, private,
/// link-local, carrier-grade-NAT, unique-local, multicast, and special-use
/// names are all refused so a crafted invite cannot make NotchHub poke at a
/// router admin page or a link-local metadata service.
enum SafeExternalURL {
    private static let meetingSchemes: Set<String> = ["facetime", "msteams", "webex", "zoommtg"]

    /// Special-use and reserved top-level labels (RFC 2606 / RFC 6761 / RFC 8375).
    private static let reservedTopLevelLabels: Set<String> = [
        "local", "localhost", "internal", "intranet", "private", "corp",
        "home", "lan", "test", "example", "invalid", "onion", "alt"
    ]

    private static let maximumHostLength = 253
    private static let maximumURLLength = 2_048

    static func meetingURL(_ url: URL?) -> URL? {
        guard let url,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= maximumURLLength,
              let scheme = url.scheme?.lowercased()
        else {
            return nil
        }

        if meetingSchemes.contains(scheme) {
            return url
        }

        guard scheme == "https", let host = url.host, isPublicHost(host) else {
            return nil
        }
        return url
    }

    static func mapsURL(for location: String) -> URL? {
        // Sanitize first, then bound: an over-long location is refused rather
        // than silently truncated into a different place name.
        let cleaned = DisplaySanitizer.text(location, limit: 301)
        guard !cleaned.isEmpty, cleaned.count <= 300 else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: cleaned)]
        return components?.url
    }

    // MARK: - Host classification

    static func isPublicHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        guard !host.isEmpty, host.utf8.count <= maximumHostLength else { return false }
        // A single trailing dot is a legal FQDN root; strip it before matching.
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        if let address = ipv6Bytes(host) { return isPublicIPv6(address) }
        // Anything that *looks* numeric must parse as a canonical dotted quad.
        // Octal, hex, and dword spellings (`0177.0.0.1`, `0x7f000001`, `127.1`)
        // are refused outright: `inet_pton` reads `0177` as decimal 177 while
        // the URL loader resolves it as octal 127, and a check that disagrees
        // with the resolver is worse than no check at all.
        guard !looksNumeric(host) else {
            guard let address = canonicalIPv4(host) else { return false }
            return isPublicIPv4(address)
        }
        return isPublicName(host)
    }

    private static func looksNumeric(_ host: String) -> Bool {
        if host.contains(":") { return true }
        guard let last = host.split(separator: ".").last else { return true }
        if last.hasPrefix("0x") { return true }
        return last.allSatisfy(\.isNumber)
    }

    private static func isPublicName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels where !isValidLabel(label) { return false }

        guard let topLevel = labels.last.map(String.init),
              !reservedTopLevelLabels.contains(topLevel)
        else {
            return false
        }
        // `*.arpa` covers home.arpa (RFC 8375) and the reverse-DNS trees.
        return topLevel != "arpa"
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-" else {
            return false
        }
        return label.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    // MARK: - IPv4

    /// Strict dotted-quad parser: exactly four decimal labels, 1–3 digits each,
    /// no leading zeros, each ≤ 255. Deliberately hand-rolled so it cannot
    /// disagree with the system resolver the way `inet_pton` does on `0177`.
    private static func canonicalIPv4(_ host: String) -> UInt32? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return nil }

        var address: UInt32 = 0
        for label in labels {
            guard (1 ... 3).contains(label.count),
                  label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  label.count == 1 || label.first != "0",
                  let octet = UInt32(label), octet <= 255
            else {
                return nil
            }
            address = address << 8 | octet
        }
        return address
    }

    /// Every IPv4 range that is not globally routable unicast (RFC 6890).
    private static let reservedIPv4Blocks: [(base: UInt32, prefix: UInt32)] = [
        (0x0000_0000, 8), // 0.0.0.0/8      "this" network
        (0x0A00_0000, 8), // 10.0.0.0/8     private
        (0x6440_0000, 10), // 100.64.0.0/10  carrier-grade NAT
        (0x7F00_0000, 8), // 127.0.0.0/8    loopback
        (0xA9FE_0000, 16), // 169.254.0.0/16 link-local
        (0xAC10_0000, 12), // 172.16.0.0/12  private
        (0xC000_0000, 24), // 192.0.0.0/24   IETF protocol assignments
        (0xC000_0200, 24), // 192.0.2.0/24   TEST-NET-1
        (0xC058_6300, 24), // 192.88.99.0/24 6to4 relay anycast
        (0xC0A8_0000, 16), // 192.168.0.0/16 private
        (0xC612_0000, 15), // 198.18.0.0/15  benchmarking
        (0xC633_6400, 24), // 198.51.100.0/24 TEST-NET-2
        (0xCB00_7100, 24), // 203.0.113.0/24 TEST-NET-3
        (0xE000_0000, 4), // 224.0.0.0/4    multicast
        (0xF000_0000, 4) // 240.0.0.0/4    reserved + broadcast
    ]

    private static func isPublicIPv4(_ address: UInt32) -> Bool {
        !reservedIPv4Blocks.contains { block in
            let mask: UInt32 = block.prefix == 0 ? 0 : ~UInt32(0) << (32 - block.prefix)
            return address & mask == block.base & mask
        }
    }

    // MARK: - IPv6

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let parsed = host.withCString { cString in
            bytes.withUnsafeMutableBytes { buffer in
                inet_pton(AF_INET6, cString, buffer.baseAddress)
            }
        }
        return parsed == 1 ? bytes : nil
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        // `::` and `::1`
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return false }
        // IPv4-mapped / IPv4-compatible: judge the embedded IPv4 address instead.
        if let embedded = embeddedIPv4(bytes) { return isPublicIPv4(embedded) }
        return !isReservedIPv6Prefix(bytes)
    }

    /// The IPv4 address a transition-prefix IPv6 address embeds, or nil when no
    /// well-defined embedding applies.
    ///
    /// An IPv6 literal can carry an IPv4 address inside it, and several of those
    /// forms would otherwise read as an ordinary public IPv6 address — so
    /// `[64:ff9b::7f00:1]` is 127.0.0.1 wearing a public-looking prefix. Only
    /// prefixes with a single, documented embedding are decoded here; local-use
    /// and obfuscated transition prefixes are refused wholesale by
    /// `isReservedIPv6Prefix` instead, since there is no one address to judge.
    private static func embeddedIPv4(_ bytes: [UInt8]) -> UInt32? {
        // 6to4 (RFC 3056): 2002::/16, tunnel endpoint IPv4 at bytes 2-5.
        if bytes[0] == 0x20, bytes[1] == 0x02 { return quad(bytes, at: 2) }
        // NAT64 well-known prefix (RFC 6052): 64:ff9b::a.b.c.d, quad at 12-15.
        // The zero run rules out the local-use /48 (64:ff9b:1::), refused below.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B,
           bytes[4 ..< 12].allSatisfy({ $0 == 0 }) {
            return quad(bytes, at: 12)
        }
        // IPv4-translated (RFC 2765): ::ffff:0:a.b.c.d.
        if bytes[0 ..< 8].allSatisfy({ $0 == 0 }), bytes[8] == 0xFF, bytes[9] == 0xFF,
           bytes[10] == 0, bytes[11] == 0 {
            return quad(bytes, at: 12)
        }
        // IPv4-mapped / IPv4-compatible (RFC 4291): ::ffff:a.b.c.d and ::a.b.c.d.
        guard bytes[0 ..< 10].allSatisfy({ $0 == 0 }) else { return nil }
        let isMapped = bytes[10] == 0xFF && bytes[11] == 0xFF
        let isCompatible = bytes[10] == 0 && bytes[11] == 0
        guard isMapped || isCompatible else { return nil }
        return quad(bytes, at: 12)
    }

    private static func quad(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func isReservedIPv6Prefix(_ bytes: [UInt8]) -> Bool {
        if bytes[0] & 0xFE == 0xFC { return true } // fc00::/7  unique-local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true } // fe80::/10 link-local
        if bytes[0] == 0xFF { return true } // ff00::/8  multicast
        if isTeredoIPv6(bytes) { return true }
        if isLocalUseNAT64IPv6(bytes) { return true }
        if isDocumentationIPv6(bytes) { return true } // 2001:db8::/32
        // 100::/64 discard-only
        return bytes[0] == 0x01 && bytes[1] == 0x00 && bytes[2 ... 7].allSatisfy { $0 == 0 }
    }

    /// Teredo (RFC 4380): 2001::/32. It embeds two IPv4 addresses — the server's
    /// in clear, the client's XOR-obfuscated — so there is no single address to
    /// judge. Fail closed. (2001:db8::/32 documentation has a non-zero third
    /// hextet, so it never collides with this.)
    private static func isTeredoIPv6(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00
    }

    /// Local-use NAT64 (RFC 8215): 64:ff9b:1::/48. Defined for translation
    /// inside one network, so anything under it points at that network's own
    /// translator — even an embedded address that reads as public. Fail closed.
    private static func isLocalUseNAT64IPv6(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
            && bytes[4] == 0x00 && bytes[5] == 0x01
    }

    private static func isDocumentationIPv6(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8
    }
}
