import Foundation
import Testing
@testable import SwitcherCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var requests: [(url: URL, headers: [String: String])] = []
    /// Response per bearer token; missing token → network error.
    var responses: [String: (Int, String)] = [:]

    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        requests.append((url, headers))
        let token = headers["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        guard let r = responses[token] else { throw URLError(.notConnectedToInternet) }
        return (r.0, Data(r.1.utf8))
    }
}

let fullUsageJSON = #"{"five_hour":{"utilization":42,"resets_at":"2026-11-21T15:10:00Z"},"seven_day":{"utilization":23,"resets_at":"2026-11-24T10:00:00.123+00:00"},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"utilization":24.8,"currency":"EUR","decimal_places":2,"spend_limit_reached":false},"unknown_thing":{"x":1}}"#

@Suite struct UsageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesFiveHourWeeklyAndExtra() throws {
        let u = try UsageParser.parse(Data(fullUsageJSON.utf8), fetchedAt: now)
        #expect(u.session == UsageWindow(utilization: 42, resetsAt: ISO8601DateFormatter().date(from: "2026-11-21T15:10:00Z")))
        #expect(u.weekly?.utilization == 23)
        #expect(u.weekly?.resetsAt != nil)
        #expect(u.extra == ExtraUsage(isEnabled: true, monthlyLimit: 5000, usedCredits: 1240, utilization: 24.8,
                                      currency: "EUR", decimalPlaces: 2, spendLimitReached: false))
        #expect(u.isLive && u.fetchedAt == now)
    }

    @Test func parsesNullWindowsAndMissingExtra() throws {
        let u = try UsageParser.parse(Data(#"{"five_hour":null,"seven_day":{"utilization":27,"resets_at":null}}"#.utf8), fetchedAt: now)
        #expect(u.session == nil)
        #expect(u.weekly == UsageWindow(utilization: 27, resetsAt: nil))
        #expect(u.extra == nil)
    }

    @Test func parseRejectsNonObject() {
        #expect(throws: (any Error).self) { try UsageParser.parse(Data("<html>".utf8), fetchedAt: now) }
    }

    @Test func parseCacheRequiresMatchingAccount() throws {
        let json = #"{"numStartups":1,"cachedUsageUtilization":{"fetchedAtMs":1700000000000,"accountUuid":"A","utilization":\#(fullUsageJSON)}}"#
        let cached = try #require(UsageParser.parseCache(Data(json.utf8), accountUuid: "A"))
        #expect(!cached.isLive)
        #expect(cached.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(cached.session?.utilization == 42)
        #expect(UsageParser.parseCache(Data(json.utf8), accountUuid: "B") == nil)
        #expect(UsageParser.parseCache(Data(#"{"x":1}"#.utf8), accountUuid: "A") == nil)
    }

    @Test func extraFormatsCurrency() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 5000, usedCredits: 1240, utilization: nil,
                               currency: "EUR", decimalPlaces: 2, spendLimitReached: false)
        let s = extra.formatted(1240)
        #expect(s.contains("€"))
        #expect(s.contains("12.40") || s.contains("12,40"))
    }

    @Test func clientSendsBearerAndBetaHeaders() async throws {
        let http = FakeHTTP()
        http.responses["tok"] = (200, fullUsageJSON)
        let u = try await UsageClient(http: http).fetch(accessToken: "tok")
        #expect(u.session?.utilization == 42)
        let req = try #require(http.requests.first)
        #expect(req.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(req.headers["Authorization"] == "Bearer tok")
        #expect(req.headers["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test func clientThrowsHttpErrorOn401() async {
        let http = FakeHTTP()
        http.responses["tok"] = (401, "{}")
        await #expect(throws: UsageError.http(401)) { _ = try await UsageClient(http: http).fetch(accessToken: "tok") }
    }

    @Test func clientThrowsBadResponseOnGarbage() async {
        let http = FakeHTTP()
        http.responses["tok"] = (200, "<html>")
        await #expect(throws: UsageError.badResponse) { _ = try await UsageClient(http: http).fetch(accessToken: "tok") }
    }

    @Test func credentialsParseAccessTokenAndExpiry() throws {
        let blob = #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":1763740800000},"mcpOAuth":{}}"#
        let c = try #require(OAuthCredentials.parse(Data(blob.utf8)))
        #expect(c.accessToken == "t")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_763_740_800))
        #expect(OAuthCredentials.parse(Data("nope".utf8)) == nil)
        #expect(c.isValid(at: Date(timeIntervalSince1970: 1_763_740_800 - 120)))
        #expect(!c.isValid(at: Date(timeIntervalSince1970: 1_763_740_800 - 30)))
    }

    @Test func unknownCurrencyFormatsAsPlainNumber() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: nil, usedCredits: 1240, utilization: nil,
                               currency: nil, decimalPlaces: 2, spendLimitReached: false)
        #expect(extra.formatted(1240) == "12.40")
    }

    @Test func terminalCommandIsQuoted() {
        let script = LoginLauncher.terminalScript(claudePath: "/Users/a b/it's/claude")
        #expect(script.contains(#"'/Users/a b/it'\\''s/claude' auth login"#))
    }
}
