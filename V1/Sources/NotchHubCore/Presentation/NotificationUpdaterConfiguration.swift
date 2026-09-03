import Foundation

/// Pure validation performed before the direct build constructs Sparkle.
public struct UpdateFeedConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String

    public init?(infoDictionary: [String: Any]) {
        guard let feedValue = infoDictionary["SUFeedURL"] as? String,
              let keyValue = infoDictionary["SUPublicEDKey"] as? String,
              let feedURL = Self.validatedFeedURL(feedValue),
              Self.isValidPublicKey(keyValue)
        else { return nil }

        self.feedURL = feedURL
        self.publicKey = keyValue
    }

    private static func validatedFeedURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return nil }
        return components.url
    }

    private static func isValidPublicKey(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let keyData = Data(base64Encoded: value),
              keyData.count == 32
        else { return false }
        return keyData.contains { $0 != 0 }
    }
}
