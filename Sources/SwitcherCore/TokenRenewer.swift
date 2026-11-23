import Foundation

/// Renews an expired Claude Code access token the same way Claude Code does (OAuth refresh grant),
/// returning the updated Keychain blob. Everything else in the blob (e.g. MCP logins) is kept.
public struct TokenRenewer: Sendable {
    public enum RenewalError: Error, Equatable { case rejected(Int), badResponse }

    public static let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Renew a little before expiry, like Claude Code.
    public static let margin: TimeInterval = 5 * 60

    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// nil when the login is still valid (or has nothing to renew with).
    public func renewIfNeeded(_ blob: Data, now: Date) async throws -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty,
              let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        guard expiresAt / 1000 - now.timeIntervalSince1970 <= Self.margin else { return nil }

        var request: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientId]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty { request["scope"] = scopes.joined(separator: " ") }
        let (status, data) = try await http.post(Self.url, headers: ["Content-Type": "application/json"],
                                                 body: try JSONSerialization.data(withJSONObject: request))
        guard status == 200 else { throw RenewalError.rejected(status) }
        guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = answer["access_token"] as? String,
              let expiresIn = (answer["expires_in"] as? NSNumber)?.doubleValue else { throw RenewalError.badResponse }

        oauth["accessToken"] = access
        oauth["refreshToken"] = (answer["refresh_token"] as? String) ?? refresh
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        root["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: root)
    }
}
