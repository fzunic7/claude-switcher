import Foundation
import Testing
@testable import SwitcherCore

@Suite struct ProfileStoreTests {
    @Test func loadMissingFileReturnsEmpty() throws {
        let store = ProfileStore(root: try makeTempDir().appendingPathComponent("nested"))
        let state = try store.load()
        #expect(state.profiles == [])
        #expect(state.activeId == nil)
    }

    @Test func roundTripPreservesNestedOauthAccount() throws {
        let store = ProfileStore(root: try makeTempDir())
        let account: [String: JSONValue] = [
            "accountUuid": .string("a"),
            "nested": .object(["n": .number(3.5), "flag": .bool(true), "none": .null]),
            "list": .array([.string("x"), .number(1)]),
        ]
        let profile = Profile(id: "a", label: "Main", role: .main, orgUuid: "o", email: "m@example.com",
                              oauthAccount: account, hasDesktopSnapshot: false)
        let state = SwitcherState(profiles: [profile], activeId: "a", sharedSessionIds: ["local_1"], shareAll: false)
        try store.save(state)
        #expect(try store.load() == state)
    }

    @Test func savedFileHasMode0600() throws {
        let root = try makeTempDir()
        let store = ProfileStore(root: root)
        try store.save(SwitcherState())
        #expect(try posixMode(root.appendingPathComponent("profiles.json")) == 0o600)
    }
}

@Suite struct StateV2Tests {
    @Test func loadsStateWrittenByPreviousVersion() throws {
        let root = try makeTempDir()
        let v1 = #"{"profiles":[{"id":"a","label":"Main","role":"main","orgUuid":"o","email":"a@x","oauthAccount":{},"hasDesktopSnapshot":false}],"activeId":"a","sharedSessionIds":[],"shareAll":false}"#
        try Data(v1.utf8).write(to: root.appendingPathComponent("profiles.json"))
        let state = try ProfileStore(root: root).load()
        #expect(state.profiles.count == 1)
        #expect(state.activeId == "a")
        #expect(state.lastUsage == [:])
        #expect(state.ignoredAccountId == nil)
        #expect(state.desktopAccountId == nil)
    }

    @Test func roundTripPreservesNewFields() throws {
        let store = ProfileStore(root: try makeTempDir())
        let usage = AccountUsage(session: UsageWindow(utilization: 42, resetsAt: Date(timeIntervalSince1970: 1_000)),
                                 weekly: UsageWindow(utilization: 23, resetsAt: nil),
                                 extra: ExtraUsage(isEnabled: true, monthlyLimit: 5000, usedCredits: 1240, utilization: 24.8,
                                                   currency: "EUR", decimalPlaces: 2, spendLimitReached: false),
                                 fetchedAt: Date(timeIntervalSince1970: 2_000), isLive: true)
        var state = SwitcherState()
        state.ignoredAccountId = "x"
        state.desktopAccountId = "a"
        state.desktopAppliedAt = Date(timeIntervalSince1970: 3_000)
        state.lastUsage = ["a": usage]
        try store.save(state)
        #expect(try store.load() == state)
    }

    @Test func planBadgeFromOrganizationType() {
        func profile(_ type: String?) -> Profile {
            Profile(id: "a", label: "a", role: .main, orgUuid: "o", email: "a@x",
                    oauthAccount: type.map { ["organizationType": .string($0)] } ?? [:], hasDesktopSnapshot: false)
        }
        #expect(profile("claude_max").plan == "Max")
        #expect(profile("claude_pro").plan == "Pro")
        #expect(profile("claude_team").plan == "Team")
        #expect(profile("claude_enterprise").plan == "Enterprise")
        #expect(profile("something_else").plan == nil)
        #expect(profile(nil).plan == nil)
    }
}
