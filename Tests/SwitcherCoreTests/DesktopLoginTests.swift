import Foundation
import Testing
@testable import SwitcherCore

@Suite struct DesktopLoginTests {
    let fm = FileManager.default

    func setup() throws -> (support: URL, vault: URL, login: DesktopLoginFiles) {
        let base = try makeTempDir()
        let support = base.appendingPathComponent("Claude")
        let vault = base.appendingPathComponent("vault")
        try fm.createDirectory(at: support.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("claude-code-sessions"), withIntermediateDirectories: true)
        try write("cookies-A", support.appendingPathComponent("Cookies"))
        try write("ls-A", support.appendingPathComponent("Local Storage/leveldb"))
        try write("sessions", support.appendingPathComponent("claude-code-sessions/x.json"))
        let login = DesktopLoginFiles(supportRoot: support, vaultRoot: vault, paths: ["Cookies", "Local Storage", "IndexedDB"])
        return (support, vault, login)
    }

    func write(_ s: String, _ url: URL) throws { try Data(s.utf8).write(to: url) }
    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    @Test func captureCopiesListedPathsOnly() throws {
        let (_, vault, login) = try setup()
        try login.capture(into: "A")
        let snap = vault.appendingPathComponent("A/desktop")
        #expect(try read(snap.appendingPathComponent("Cookies")) == "cookies-A")
        #expect(try read(snap.appendingPathComponent("Local Storage/leveldb")) == "ls-A")
        #expect(!fm.fileExists(atPath: snap.appendingPathComponent("claude-code-sessions").path))
        #expect(login.hasSnapshot("A"))
        #expect(!login.hasSnapshot("B"))
    }

    @Test func applyReplacesListedPaths() throws {
        let (support, _, login) = try setup()
        try login.capture(into: "A")
        try write("cookies-B", support.appendingPathComponent("Cookies"))
        try write("stale", support.appendingPathComponent("Local Storage/stale"))
        try login.apply(from: "A")
        #expect(try read(support.appendingPathComponent("Cookies")) == "cookies-A")
        #expect(!fm.fileExists(atPath: support.appendingPathComponent("Local Storage/stale").path))
    }

    @Test func applyLeavesUnlistedPathsUntouched() throws {
        let (support, _, login) = try setup()
        try login.capture(into: "A")
        try write("sessions-new", support.appendingPathComponent("claude-code-sessions/x.json"))
        try login.apply(from: "A")
        #expect(try read(support.appendingPathComponent("claude-code-sessions/x.json")) == "sessions-new")
    }

    @Test func applyRemovesListedPathMissingFromSnapshot() throws {
        let (support, _, login) = try setup()
        try login.capture(into: "A")
        try fm.createDirectory(at: support.appendingPathComponent("IndexedDB"), withIntermediateDirectories: true)
        try login.apply(from: "A")
        #expect(!fm.fileExists(atPath: support.appendingPathComponent("IndexedDB").path))
    }

    @Test func backupAndRestoreRoundTrip() throws {
        let (support, _, login) = try setup()
        let backup = try login.backupCurrent()
        try write("changed", support.appendingPathComponent("Cookies"))
        try login.restore(from: backup)
        #expect(try read(support.appendingPathComponent("Cookies")) == "cookies-A")
    }

    @Test func vaultDirIsMode0700() throws {
        let (_, vault, login) = try setup()
        try login.capture(into: "A")
        #expect(try posixMode(vault.appendingPathComponent("A")) == 0o700)
    }

    @Test func missingSourcePathIsSkipped() throws {
        let (_, vault, login) = try setup()
        try login.capture(into: "A")
        #expect(!fm.fileExists(atPath: vault.appendingPathComponent("A/desktop/IndexedDB").path))
    }
}
