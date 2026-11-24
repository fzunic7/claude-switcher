import Foundation
import Testing
@testable import SwitcherCore

@Suite struct SessionIndexTests {
    let fm = FileManager.default

    func record(_ title: String, _ last: Int, archived: Bool = false) -> Data {
        Data(#"{"sessionId":"s","cliSessionId":"c","cwd":"/w","title":"\#(title)","lastActivityAt":\#(last),"isArchived":\#(archived),"extra":{"k":1}}"#.utf8)
    }

    func setup() throws -> (root: URL, index: SessionIndex) {
        let root = try makeTempDir()
        let dir = root.appendingPathComponent("A/O")
        try fm.createDirectory(at: dir.appendingPathComponent("backlog"), withIntermediateDirectories: true)
        try record("old", 1000).write(to: dir.appendingPathComponent("local_1.json"))
        try record("new", 5000).write(to: dir.appendingPathComponent("local_2.json"))
        try record("arch", 9000, archived: true).write(to: dir.appendingPathComponent("local_3.json"))
        try record("gone", 9999).write(to: dir.appendingPathComponent("deleted_local_4.json"))
        return (root, SessionIndex(sessionsRoot: root))
    }

    @Test func listIgnoresDeletedAndBacklog() throws {
        let (_, index) = try setup()
        let ids = try index.list(account: "A", org: "O").map(\.id)
        #expect(!ids.contains { $0.hasPrefix("deleted_") || $0 == "backlog" })
    }

    @Test func listSortsByLastActivityDesc() throws {
        let (_, index) = try setup()
        let sessions = try index.list(account: "A", org: "O")
        #expect(sessions.map(\.id) == ["local_2", "local_1"])
        #expect(sessions[0].title == "new")
        #expect(sessions[0].lastActivityAt == Date(timeIntervalSince1970: 5))
    }

    @Test func listExcludesArchived() throws {
        let (_, index) = try setup()
        #expect(!(try index.list(account: "A", org: "O").map(\.id).contains("local_3")))
    }

    @Test func listEmptyWhenFolderMissing() throws {
        let (_, index) = try setup()
        #expect(try index.list(account: "Z", org: "O") == [])
    }

    @Test func shareCopiesSelectedIntoTargetFolder() throws {
        let (root, index) = try setup()
        let copied = try index.share(ids: ["local_1"], from: ("A", "O"), to: ("B", "P"))
        #expect(copied == ["local_1"])
        let src = try Data(contentsOf: root.appendingPathComponent("A/O/local_1.json"))
        #expect(try Data(contentsOf: root.appendingPathComponent("B/P/local_1.json")) == src)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("B/P/local_2.json").path))
    }

    @Test func shareNeverOverwritesExisting() throws {
        let (root, index) = try setup()
        let target = root.appendingPathComponent("B/P")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: target.appendingPathComponent("local_1.json"))
        let copied = try index.share(ids: ["local_1"], from: ("A", "O"), to: ("B", "P"))
        #expect(copied == [])
        #expect(try Data(contentsOf: target.appendingPathComponent("local_1.json")) == Data("newer".utf8))
    }

    @Test func shareSkipsUnknownIds() throws {
        let (_, index) = try setup()
        #expect(try index.share(ids: ["local_99", "../escape"], from: ("A", "O"), to: ("B", "P")) == [])
    }

    @Test func mergeCopiesBothWaysWithoutOverwriting() throws {
        let (root, index) = try setup()                 // A/O has local_1, local_2, local_3 (archived)
        let b = root.appendingPathComponent("B/P")
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("b-version".utf8).write(to: b.appendingPathComponent("local_2.json"))
        try record("only-b", 10).write(to: b.appendingPathComponent("local_5.json"))
        let result = try index.merge(("A", "O"), ("B", "P"))
        #expect(result.toA == ["local_5"])
        #expect(result.toB == ["local_1", "local_3"])
        #expect(try Data(contentsOf: b.appendingPathComponent("local_2.json")) == Data("b-version".utf8))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("A/O/local_5.json").path))
        #expect(!fm.fileExists(atPath: b.appendingPathComponent("deleted_local_4.json").path))
    }

    @Test func mergeDoesNotResurrectDeletedSessions() throws {
        let (root, index) = try setup()                 // A/O has local_1, local_2, local_3, deleted_local_4
        let b = root.appendingPathComponent("B/P")
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try record("still-in-b", 10).write(to: b.appendingPathComponent("local_4.json"))
        try marker(root.appendingPathComponent("A/O"), "4")            // the marker Claude Desktop really writes
        let result = try index.merge(("A", "O"), ("B", "P"))
        #expect(!result.toA.contains("local_4"))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("A/O/local_4.json").path))
    }

    @Test func mergeRefreshesOlderCopyWithNewerRecord() throws {
        let (root, index) = try setup()                 // A/O local_2 has lastActivityAt 5000
        let b = root.appendingPathComponent("B/P")
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try record("old-title", 1000).write(to: b.appendingPathComponent("local_2.json"))
        let result = try index.merge(("A", "O"), ("B", "P"))
        #expect(result.toB.contains("local_2"))
        #expect(try Data(contentsOf: b.appendingPathComponent("local_2.json")) == Data(contentsOf: root.appendingPathComponent("A/O/local_2.json")))
    }

    // Claude Desktop deletes a session by removing local_<uuid>.json and writing a marker file deleted_<uuid>.
    func marker(_ dir: URL, _ uuid: String) throws { try Data("1795000000000".utf8).write(to: dir.appendingPathComponent("deleted_\(uuid)")) }

    @Test func deletionCarriesOverToTheOtherAccount() throws {
        let root = try makeTempDir()
        let a = root.appendingPathComponent("A/O"), b = root.appendingPathComponent("B/P")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try marker(a, "u1")                                              // deleted under A
        try record("t", 10).write(to: b.appendingPathComponent("local_u1.json"))   // still under B
        let trash = root.appendingPathComponent("trash")
        _ = try SessionIndex(sessionsRoot: root, trashRoot: trash).merge(("A", "O"), ("B", "P"))
        #expect(!fm.fileExists(atPath: b.appendingPathComponent("local_u1.json").path))
        #expect(fm.fileExists(atPath: b.appendingPathComponent("deleted_u1").path))
        #expect(!fm.fileExists(atPath: a.appendingPathComponent("local_u1.json").path))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).contains { $0.contains("local_u1") })
    }

    @Test func recordBroughtBackNextToItsMarkerIsCleanedUp() throws {
        let root = try makeTempDir()
        let a = root.appendingPathComponent("A/O")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try marker(a, "u2")
        try record("t", 10).write(to: a.appendingPathComponent("local_u2.json"))
        _ = try SessionIndex(sessionsRoot: root, trashRoot: root.appendingPathComponent("trash")).merge(("A", "O"), ("B", "P"))
        #expect(!fm.fileExists(atPath: a.appendingPathComponent("local_u2.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("B/P/local_u2.json").path))
    }

    @Test func listHidesDeletedSessions() throws {
        let root = try makeTempDir()
        let a = root.appendingPathComponent("A/O")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try record("gone", 10).write(to: a.appendingPathComponent("local_u3.json"))
        try marker(a, "u3")
        #expect(try SessionIndex(sessionsRoot: root).list(account: "A", org: "O").isEmpty)
    }
}
