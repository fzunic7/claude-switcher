import Foundation
import Testing
@testable import SwitcherCore

/// Accounts A (live in the CLI) and B (saved), with an in-memory keychain and fake HTTP.
final class UsageWorld {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let secrets = InMemorySecretStore()
    let http = FakeHTTP()
    let store: ProfileStore
    let claudeJSONURL: URL

    init() throws {
        let base = try makeTempDir()
        store = ProfileStore(root: base.appendingPathComponent("switcher"))
        claudeJSONURL = base.appendingPathComponent(".claude.json")
        try writeClaudeJSON(cache: nil)
        try store.save(SwitcherState(profiles: [profile("A"), profile("B")], activeId: "A"))
        try saveToken(ServiceNames.claudeCode, "tok-A", expiresIn: 3600)
        try saveToken(ServiceNames.vault("A"), "tok-A", expiresIn: 3600)
        try saveToken(ServiceNames.vault("B"), "tok-B", expiresIn: 3600)
    }

    func profile(_ id: String) -> Profile {
        Profile(id: id, label: id, role: id == "A" ? .main : .backup, orgUuid: "o", email: "\(id)@x",
                oauthAccount: ["accountUuid": .string(id)], hasDesktopSnapshot: false)
    }

    func saveToken(_ service: String, _ token: String, expiresIn: TimeInterval) throws {
        let ms = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        try secrets.write(service: service, account: "unknown",
                          secret: Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","expiresAt":\#(ms)}}"#.utf8))
    }

    func writeClaudeJSON(cache: (account: String, fetchedAt: Date, session: Int)?) throws {
        var json = #"{"oauthAccount":{"accountUuid":"A"}"#
        if let cache {
            json += #","cachedUsageUtilization":{"fetchedAtMs":\#(Int(cache.fetchedAt.timeIntervalSince1970 * 1000)),"accountUuid":"\#(cache.account)","utilization":{"five_hour":{"utilization":\#(cache.session),"resets_at":null}}}"#
        }
        try Data((json + "}").utf8).write(to: claudeJSONURL)
    }

    func usageJSON(_ session: Int) -> String { #"{"five_hour":{"utilization":\#(session),"resets_at":null}}"# }

    var service: UsageService {
        let now = self.now
        return UsageService(secrets: secrets, claudeJSON: ClaudeJSON(url: claudeJSONURL), store: store,
                            client: UsageClient(http: http), now: { now })
    }

    func setLastUsage(_ id: String, session: Double, at: Date) throws {
        var state = try store.load()
        state.lastUsage[id] = AccountUsage(session: UsageWindow(utilization: session, resetsAt: nil), weekly: nil,
                                           extra: nil, fetchedAt: at, isLive: true)
        try store.save(state)
    }
}

@Suite struct UsageServiceTests {
    @Test func activeUsesLiveToken() async throws {
        let w = try UsageWorld()
        w.http.responses["tok-A"] = (200, w.usageJSON(42))
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let result = await w.service.refresh()
        #expect(result["A"]?.session?.utilization == 42 && result["A"]?.isLive == true)
    }

    @Test func inactiveWithValidSavedTokenFetchesLive() async throws {
        let w = try UsageWorld()
        w.http.responses["tok-A"] = (200, w.usageJSON(42))
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let result = await w.service.refresh()
        #expect(result["B"]?.session?.utilization == 5 && result["B"]?.isLive == true)
    }

    @Test func inactiveWithExpiredTokenMakesNoRequestAndReturnsLastKnown() async throws {
        let w = try UsageWorld()
        try w.saveToken(ServiceNames.vault("B"), "tok-B", expiresIn: -10)
        try w.setLastUsage("B", session: 17, at: Date(timeIntervalSince1970: 1_700_000_000))
        w.http.responses["tok-A"] = (200, w.usageJSON(42))
        let result = await w.service.refresh()
        #expect(!w.http.requests.contains { $0.headers["Authorization"] == "Bearer tok-B" })
        #expect(result["B"]?.session?.utilization == 17)
        #expect(result["B"]?.isLive == false)
        #expect(result["B"]?.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func activeFailureFallsBackToClaudeCodeCache() async throws {
        let w = try UsageWorld()
        try w.writeClaudeJSON(cache: ("A", Date(timeIntervalSince1970: 1_799_999_000), 61))
        w.http.responses["tok-A"] = (401, "{}")
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let result = await w.service.refresh()
        #expect(result["A"]?.session?.utilization == 61)
        #expect(result["A"]?.isLive == false)
    }

    @Test func activeFailurePrefersNewerLastKnownOverOlderCache() async throws {
        let w = try UsageWorld()
        try w.writeClaudeJSON(cache: ("A", Date(timeIntervalSince1970: 1_700_000_000), 61))
        try w.setLastUsage("A", session: 70, at: Date(timeIntervalSince1970: 1_750_000_000))
        w.http.responses["tok-A"] = (401, "{}")
        let result = await w.service.refresh()
        #expect(result["A"]?.session?.utilization == 70)
    }

    @Test func failureForOneAccountDoesNotAffectOther() async throws {
        let w = try UsageWorld()
        try w.setLastUsage("A", session: 33, at: Date(timeIntervalSince1970: 1_700_000_000))
        w.http.responses["tok-A"] = (429, "{}")
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        let result = await w.service.refresh()
        #expect(result["A"]?.session?.utilization == 33 && result["A"]?.isLive == false)
        #expect(result["B"]?.session?.utilization == 5 && result["B"]?.isLive == true)
    }

    @Test func successIsPersistedToLastUsage() async throws {
        let w = try UsageWorld()
        w.http.responses["tok-A"] = (200, w.usageJSON(42))
        w.http.responses["tok-B"] = (200, w.usageJSON(5))
        _ = await w.service.refresh()
        let state = try w.store.load()
        #expect(state.lastUsage["A"]?.session?.utilization == 42)
        #expect(state.lastUsage["B"]?.session?.utilization == 5)
        #expect(state.activeId == "A" && state.profiles.count == 2)
    }

    @Test func unknownAccountWithNoDataIsOmitted() async throws {
        let w = try UsageWorld()
        try w.secrets.delete(service: ServiceNames.vault("B"))
        w.http.responses["tok-A"] = (200, w.usageJSON(42))
        let result = await w.service.refresh()
        #expect(result["B"] == nil)
        #expect(result["A"] != nil)
    }
}
