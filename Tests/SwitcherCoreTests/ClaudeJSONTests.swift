import Foundation
import Testing
@testable import SwitcherCore

@Suite struct ClaudeJSONTests {
    let fixture = #"{"numStartups":42,"projects":{"/a":{"x":1}},"oauthAccount":{"accountUuid":"a","emailAddress":"a@x"}}"#

    func makeFile() throws -> URL {
        let url = try makeTempDir().appendingPathComponent(".claude.json")
        try Data(fixture.utf8).write(to: url)
        return url
    }

    func object(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func readAccountReturnsOauthAccount() throws {
        let account = try ClaudeJSON(url: makeFile()).readAccount()
        #expect(account?["accountUuid"] == .string("a"))
    }

    @Test func readAccountNilWhenMissing() throws {
        let url = try makeTempDir().appendingPathComponent(".claude.json")
        try Data(#"{"numStartups":1}"#.utf8).write(to: url)
        #expect(try ClaudeJSON(url: url).readAccount() == nil)
    }

    @Test func writeAccountPreservesOtherKeys() throws {
        let url = try makeFile()
        try ClaudeJSON(url: url).writeAccount(["accountUuid": .string("b")])
        let obj = try object(url)
        #expect(obj["numStartups"] as? Int == 42)
        #expect((obj["projects"] as? [String: Any])?["/a"] as? [String: Int] == ["x": 1])
        #expect((obj["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "b")
    }

    @Test func writeAccountRereadsFileBeforeWriting() throws {
        let url = try makeFile()
        let editor = ClaudeJSON(url: url)
        _ = try editor.readAccount()
        var obj = try object(url)
        obj["x"] = "added-by-claude"
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        try editor.writeAccount(["accountUuid": .string("b")])
        #expect(try object(url)["x"] as? String == "added-by-claude")
    }

    @Test func writeAccountCreatesBackup() throws {
        let url = try makeFile()
        try ClaudeJSON(url: url).writeAccount(["accountUuid": .string("b")])
        let backup = url.deletingLastPathComponent().appendingPathComponent(".claude.json.switcher-bak")
        #expect(try Data(contentsOf: backup) == Data(fixture.utf8))
    }

    @Test func restoreWritesExactBytes() throws {
        let url = try makeFile()
        let editor = ClaudeJSON(url: url)
        let original = try editor.rawContents()
        try editor.writeAccount(["accountUuid": .string("b")])
        try editor.restore(original)
        #expect(try Data(contentsOf: url) == Data(fixture.utf8))
    }

    @Test func writeAccountDoesNotEscapeSlashes() throws {
        let url = try makeFile()
        try ClaudeJSON(url: url).writeAccount(["accountUuid": .string("b")])
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.contains("\"/a\""))
        #expect(!text.contains("\\/"))
    }
}
