import Foundation
import Testing
@testable import SwitcherCore

func credsBlob(access: String, refresh: String, expiresAt: Date) -> Data {
    let ms = Int(expiresAt.timeIntervalSince1970 * 1000)
    return Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresAt":\#(ms),"scopes":["user:inference","user:profile"],"subscriptionType":"team"},"mcpOAuth":{"server":{"t":1}}}"#.utf8)
}

@Suite struct TokenRenewerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func renewsAnExpiredLoginLikeClaudeCode() async throws {
        let http = FakeHTTP()
        http.renewals["r1"] = (200, #"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#)
        let old = credsBlob(access: "a1", refresh: "r1", expiresAt: now.addingTimeInterval(-60))
        let renewed = try #require(try await TokenRenewer(http: http).renewIfNeeded(old, now: now))
        let post = try #require(http.posts.first)
        #expect(post.url.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(post.body["grant_type"] as? String == "refresh_token")
        #expect(post.body["refresh_token"] as? String == "r1")
        #expect(post.body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(post.body["scope"] as? String == "user:inference user:profile")
        let creds = try #require(OAuthCredentials.parse(renewed))
        #expect(creds.accessToken == "a2")
        #expect(creds.expiresAt == now.addingTimeInterval(28800))
        let json = try JSONSerialization.jsonObject(with: renewed) as! [String: Any]
        #expect((json["claudeAiOauth"] as! [String: Any])["refreshToken"] as? String == "r2")
        #expect((json["claudeAiOauth"] as! [String: Any])["subscriptionType"] as? String == "team")
        #expect(json["mcpOAuth"] != nil)
    }

    @Test func keepsTheOldRefreshTokenWhenNoneIsReturned() async throws {
        let http = FakeHTTP()
        http.renewals["r1"] = (200, #"{"access_token":"a2","expires_in":100}"#)
        let renewed = try await TokenRenewer(http: http).renewIfNeeded(credsBlob(access: "a1", refresh: "r1", expiresAt: now), now: now)
        let json = try JSONSerialization.jsonObject(with: try #require(renewed)) as! [String: Any]
        #expect((json["claudeAiOauth"] as! [String: Any])["refreshToken"] as? String == "r1")
    }

    @Test func validLoginIsLeftAlone() async throws {
        let http = FakeHTTP()
        let blob = credsBlob(access: "a1", refresh: "r1", expiresAt: now.addingTimeInterval(3600))
        #expect(try await TokenRenewer(http: http).renewIfNeeded(blob, now: now) == nil)
        #expect(http.posts.isEmpty)
    }

    @Test func rejectedRenewalThrows() async {
        let http = FakeHTTP()
        http.renewals["r1"] = (400, #"{"error":"invalid_grant"}"#)
        await #expect(throws: TokenRenewer.RenewalError.rejected(400)) {
            _ = try await TokenRenewer(http: http).renewIfNeeded(credsBlob(access: "a1", refresh: "r1", expiresAt: now), now: now)
        }
    }
}

func token(_ w: UsageWorld, _ service: String) -> String? {
    (try? w.secrets.read(service: service)).flatMap { $0 }.flatMap { OAuthCredentials.parse($0.secret) }?.accessToken
}

@Suite struct UsageRenewalTests {
    func blob(_ access: String, _ refresh: String, _ w: UsageWorld, expiresIn: TimeInterval) -> Data {
        credsBlob(access: access, refresh: refresh, expiresAt: w.now.addingTimeInterval(expiresIn))
    }

    @Test func expiredActiveLoginIsRenewedAndWrittenBackForClaudeCode() async throws {
        let w = try UsageWorld()
        try w.secrets.write(service: ServiceNames.claudeCode, account: "u", secret: blob("tok-A", "rA", w, expiresIn: -60))
        w.http.renewals["rA"] = (200, #"{"access_token":"tok-A2","refresh_token":"rA2","expires_in":28800}"#)
        w.http.responses["tok-A2"] = (200, w.usageJSON(73))
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let result = await w.service.refresh()
        #expect(result["A"]?.session?.utilization == 73 && result["A"]?.isLive == true)
        #expect(token(w, ServiceNames.claudeCode) == "tok-A2")
        #expect(token(w, ServiceNames.vault("A")) == "tok-A2")
    }

    @Test func expiredSavedLoginOfOtherAccountIsRenewedInItsVault() async throws {
        let w = try UsageWorld()
        try w.secrets.write(service: ServiceNames.vault("B"), account: "u", secret: blob("tok-B", "rB", w, expiresIn: -60))
        w.http.renewals["rB"] = (200, #"{"access_token":"tok-B2","refresh_token":"rB2","expires_in":28800}"#)
        w.http.responses["tok-A"] = (200, w.usageJSON(1))
        w.http.responses["tok-B2"] = (200, w.usageJSON(27))
        let result = await w.service.refresh()
        #expect(result["B"]?.session?.utilization == 27 && result["B"]?.isLive == true)
        #expect(token(w, ServiceNames.vault("B")) == "tok-B2")
    }

    @Test func claudeCodeRenewingAtTheSameTimeWins() async throws {
        let w = try UsageWorld()
        try w.secrets.write(service: ServiceNames.claudeCode, account: "u", secret: blob("tok-A", "rA", w, expiresIn: -60))
        w.http.renewals["rA"] = (200, #"{"access_token":"tok-mine","refresh_token":"rMine","expires_in":28800}"#)
        let theirs = blob("tok-theirs", "rTheirs", w, expiresIn: 28800)
        let secrets = w.secrets
        w.http.onPost = { try? secrets.write(service: ServiceNames.claudeCode, account: "u", secret: theirs) }
        w.http.responses["tok-theirs"] = (200, w.usageJSON(40))
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let result = await w.service.refresh()
        #expect(try w.secrets.read(service: ServiceNames.claudeCode)?.secret == theirs)
        #expect(result["A"]?.session?.utilization == 40)
    }

    @Test func failedRenewalFallsBackToLastKnown() async throws {
        let w = try UsageWorld()
        try w.secrets.write(service: ServiceNames.claudeCode, account: "u", secret: blob("tok-A", "rA", w, expiresIn: -60))
        try w.setLastUsage("A", session: 33, at: Date(timeIntervalSince1970: 1_700_000_000))
        w.http.renewals["rA"] = (400, #"{"error":"invalid_grant"}"#)
        let result = await w.service.refresh()
        #expect(result["A"]?.session?.utilization == 33 && result["A"]?.isLive == false)
        #expect(token(w, ServiceNames.claudeCode) == "tok-A")
    }

    @Test func tooManyRequestsBacksOffThatAccount() async throws {
        let w = try UsageWorld()
        w.http.responses["tok-A"] = (429, "{}")
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let service = w.service
        _ = await service.refresh()
        let before = w.http.requests.filter { $0.headers["Authorization"] == "Bearer tok-A" }.count
        _ = await service.refresh()
        let after = w.http.requests.filter { $0.headers["Authorization"] == "Bearer tok-A" }.count
        #expect(before == 1 && after == 1)
        #expect(w.http.requests.filter { $0.headers["Authorization"] == "Bearer tok-B" }.count == 2)
    }
}
