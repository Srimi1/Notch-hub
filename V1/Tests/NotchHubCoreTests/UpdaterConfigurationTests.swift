import Foundation
import Testing
@testable import NotchHubCore

@Suite("Signed update-feed configuration")
struct UpdaterConfigurationTests {
    @Test("Valid HTTPS feed and Ed25519 key enable updates")
    func acceptsSignedHTTPSFeed() throws {
        let configuration = try #require(UpdateFeedConfiguration(infoDictionary: validInfo))

        #expect(configuration.feedURL.absoluteString == "https://updates.notchhub.example/appcast.xml")
        #expect(configuration.publicKey == Self.validKey)
    }

    @Test(
        "Unsafe or incomplete updater configuration remains disabled",
        arguments: [
            [:],
            ["SUFeedURL": "http://updates.notchhub.example/appcast.xml", "SUPublicEDKey": Self.validKey],
            ["SUFeedURL": "https://user:secret@updates.notchhub.example/appcast.xml", "SUPublicEDKey": Self.validKey],
            ["SUFeedURL": "https://updates.notchhub.example/appcast.xml#fragment", "SUPublicEDKey": Self.validKey],
            ["SUFeedURL": "https://updates.notchhub.example/appcast.xml", "SUPublicEDKey": "not-base64"],
            ["SUFeedURL": "https://updates.notchhub.example/appcast.xml", "SUPublicEDKey": Self.shortKey],
            ["SUFeedURL": "https://updates.notchhub.example/appcast.xml", "SUPublicEDKey": Self.zeroKey],
        ]
    )
    func rejectsInvalidConfiguration(info: [String: String]) {
        #expect(UpdateFeedConfiguration(infoDictionary: info) == nil)
    }

    private var validInfo: [String: Any] {
        [
            "SUFeedURL": "https://updates.notchhub.example/appcast.xml",
            "SUPublicEDKey": Self.validKey,
        ]
    }

    private static let validKey = Data((1 ... 32).map(UInt8.init)).base64EncodedString()
    private static let shortKey = Data((1 ... 16).map(UInt8.init)).base64EncodedString()
    private static let zeroKey = Data(repeating: 0, count: 32).base64EncodedString()
}
