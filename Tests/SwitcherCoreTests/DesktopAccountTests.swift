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
