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
