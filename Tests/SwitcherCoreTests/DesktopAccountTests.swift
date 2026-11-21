import Foundation
import Testing
@testable import SwitcherCore

@Suite struct DesktopAccountTests {
    @Test func readsLastKnownAccountUuid() throws {
        let url = try makeTempDir().appendingPathComponent("config.json")
        try Data(#"{"locale":"en","lastKnownAccountUuid":"acc-1"}"#.utf8).write(to: url)
        let result = try #require(DesktopConfigReader(configURL: url).signedInAccount())
        #expect(result.id == "acc-1")
        #expect(abs(result.modifiedAt.timeIntervalSinceNow) < 60)
    }

    @Test func missingFileOrKeyReturnsNil() throws {
        let dir = try makeTempDir()
        #expect(DesktopConfigReader(configURL: dir.appendingPathComponent("none.json")).signedInAccount() == nil)
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"locale":"en"}"#.utf8).write(to: url)
        #expect(DesktopConfigReader(configURL: url).signedInAccount() == nil)
    }
}

@Suite struct ClaudeAuthStatusTests {
    @Test func parsesLoggedInStatus() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, #"{"loggedIn":true,"email":"a@x.com","orgId":"o-1","subscriptionType":"max"}"#)]
        let login = try ClaudeAuthStatus(runner: runner, claudePath: { "/bin/claude" }).current()
        #expect(login == LiveLogin(email: "a@x.com", orgId: "o-1"))
        #expect(runner.calls[0].path == "/bin/claude" && runner.calls[0].args == ["auth", "status", "--json"])
    }

    @Test func loggedOutIsNil() throws {
        let runner = RecordingRunner()
        runner.responses = [(1, #"{"loggedIn":false}"#)]
        #expect(try ClaudeAuthStatus(runner: runner, claudePath: { "/bin/claude" }).current() == nil)
    }

    @Test func unreadableOutputThrows() {
        let runner = RecordingRunner()
        runner.responses = [(0, "oops")]
        #expect(throws: SwitchError.self) { try ClaudeAuthStatus(runner: runner, claudePath: { "/bin/claude" }).current() }
    }
}
