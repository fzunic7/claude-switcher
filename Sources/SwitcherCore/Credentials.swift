import Foundation

/// The parts of a saved Claude Code login the app needs to read usage.
public struct OAuthCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date

    private struct Blob: Decodable {
        struct OAuth: Decodable { var accessToken: String; var expiresAt: Double }
        var claudeAiOauth: OAuth
    }

    public static func parse(_ secret: Data) -> OAuthCredentials? {
        guard let blob = try? JSONDecoder().decode(Blob.self, from: secret) else { return nil }
        return OAuthCredentials(accessToken: blob.claudeAiOauth.accessToken,
                                expiresAt: Date(timeIntervalSince1970: blob.claudeAiOauth.expiresAt / 1000))
    }

    public func isValid(at date: Date, margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(date) > margin
    }
}
