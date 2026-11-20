import Foundation
import Testing
@testable import SwitcherCore

final class FakeDesktop: DesktopAppControl, @unchecked Sendable {
    var isRunning: Bool
    var quits = 0, launches = 0
    init(running: Bool) { isRunning = running }
    func quit() async throws { quits += 1; isRunning = false }
    func launch() throws { launches += 1; isRunning = true }
}

struct FailingApplyLogin: DesktopLoginStore {
    let inner: DesktopLoginFiles
    func capture(into id: String) throws { try inner.capture(into: id) }
    func hasSnapshot(_ id: String) -> Bool { inner.hasSnapshot(id) }
    func apply(from id: String) throws { throw CocoaError(.fileWriteUnknown) }
    func backupCurrent() throws -> URL { try inner.backupCurrent() }
    func restore(from backup: URL) throws { try inner.restore(from: backup) }
}

/// Two accounts, A (main) and B (backup), on a temp filesystem with an in-memory keychain.
final class World {
    let base: URL
    let secrets = InMemorySecretStore()
    let desktop: FakeDesktop
    let claudeJSONURL: URL
    let support: URL
    var desktopLogin: DesktopLoginStore
    let realLogin: DesktopLoginFiles

    init(desktopRunning: Bool = true) throws {
        base = try makeTempDir()
        desktop = FakeDesktop(running: desktopRunning)
        claudeJSONURL = base.appendingPathComponent(".claude.json")
        support = base.appendingPathComponent("Claude")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        realLogin = DesktopLoginFiles(supportRoot: support, vaultRoot: base.appendingPathComponent("switcher/vault"), paths: ["Cookies"])
        desktopLogin = realLogin
    }

    var env: SwitcherEnvironment {
        SwitcherEnvironment(store: ProfileStore(root: base.appendingPathComponent("switcher")), secrets: secrets,
                            claudeJSON: ClaudeJSON(url: claudeJSONURL), desktopLogin: desktopLogin,
                            sessions: SessionIndex(sessionsRoot: support.appendingPathComponent("claude-code-sessions")),
                            desktop: desktop)
    }

    func signIn(_ id: String, token: String) throws {
        let json = #"{"numStartups":7,"oauthAccount":{"accountUuid":"\#(id)","organizationUuid":"org-\#(id)","emailAddress":"\#(id)@x"}}"#
        try Data(json.utf8).write(to: claudeJSONURL)
        try secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data(token.utf8))
        try Data("cookies-\(id)".utf8).write(to: support.appendingPathComponent("Cookies"))
    }

    func cookies() throws -> String { String(decoding: try Data(contentsOf: support.appendingPathComponent("Cookies")), as: UTF8.self) }
    func liveToken() throws -> String? { try secrets.read(service: ServiceNames.claudeCode).map { String(decoding: $0.secret, as: UTF8.self) } }
    func vaultToken(_ id: String) throws -> String? { try secrets.read(service: ServiceNames.vault(id)).map { String(decoding: $0.secret, as: UTF8.self) } }

    /// Captures A and B (both with Desktop), leaving B active.
    func captureBoth() async throws {
        try signIn("A", token: "tok-A")
        _ = try await Switcher(env: env).captureCurrent(label: "Main", role: .main, includeDesktop: true)
        try signIn("B", token: "tok-B")
        _ = try await Switcher(env: env).captureCurrent(label: "Backup", role: .backup, includeDesktop: true)
    }

    func writeSession(account: String, id: String) throws {
        let dir = support.appendingPathComponent("claude-code-sessions/\(account)/org-\(account)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"title":"t","lastActivityAt":1}"#.utf8).write(to: dir.appendingPathComponent("\(id).json"))
    }
}

@Suite struct SwitcherTests {
    @Test func captureStoresSecretAndAccount() async throws {
        let w = try World()
        try w.signIn("A", token: "tok-A")
        let p = try await Switcher(env: w.env).captureCurrent(label: "Main", role: .main, includeDesktop: false)
        #expect(p.id == "A" && p.orgUuid == "org-A" && p.email == "A@x" && !p.hasDesktopSnapshot)
        #expect(try w.vaultToken("A") == "tok-A")
        let state = try w.env.store.load()
        #expect(state.activeId == "A" && state.profiles.count == 1)
    }

    @Test func captureWithoutLiveLoginThrows() async throws {
        let w = try World()
        await #expect(throws: SwitchError.noLiveLogin) {
            _ = try await Switcher(env: w.env).captureCurrent(label: "Main", role: .main, includeDesktop: false)
        }
    }

    @Test func switchWritesTargetSecretAndAccount() async throws {
        let w = try World()
        try await w.captureBoth()
        let result = try await Switcher(env: w.env).switchTo("A")
        #expect(result.to == "A" && result.warnings.isEmpty)
        #expect(try w.liveToken() == "tok-A")
        #expect(try ClaudeJSON(url: w.claudeJSONURL).readAccount()?["accountUuid"] == .string("A"))
        #expect(try w.cookies() == "cookies-A")
        #expect(try w.env.store.load().activeId == "A")
    }

    @Test func switchSavesRefreshedLiveTokenToCurrentProfileFirst() async throws {
        let w = try World()
        try await w.captureBoth()
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-B-refreshed".utf8))
        try Data("cookies-B-refreshed".utf8).write(to: w.support.appendingPathComponent("Cookies"))
        _ = try await Switcher(env: w.env).switchTo("A")
        #expect(try w.vaultToken("B") == "tok-B-refreshed")
        _ = try await Switcher(env: w.env).switchTo("B")
        #expect(try w.liveToken() == "tok-B-refreshed")
        #expect(try w.cookies() == "cookies-B-refreshed")
    }

    @Test func switchToActiveThrowsAlreadyActive() async throws {
        let w = try World()
        try await w.captureBoth()
        await #expect(throws: SwitchError.alreadyActive) { _ = try await Switcher(env: w.env).switchTo("B") }
    }

    @Test func switchToUnknownProfileThrows() async throws {
        let w = try World()
        try await w.captureBoth()
        await #expect(throws: SwitchError.unknownProfile("Z")) { _ = try await Switcher(env: w.env).switchTo("Z") }
    }

    @Test func switchWithoutDesktopSnapshotWarnsAndLeavesDesktopFiles() async throws {
        let w = try World()
        try w.signIn("A", token: "tok-A")
        _ = try await Switcher(env: w.env).captureCurrent(label: "Main", role: .main, includeDesktop: false)
        try w.signIn("B", token: "tok-B")
        _ = try await Switcher(env: w.env).captureCurrent(label: "Backup", role: .backup, includeDesktop: false)
        let result = try await Switcher(env: w.env).switchTo("A")
        #expect(result.warnings == ["No Desktop login saved for Main; Desktop left unchanged."])
        #expect(try w.cookies() == "cookies-B")
        #expect(try w.liveToken() == "tok-A")
    }

    @Test func switchSharesSelectedSessions() async throws {
        let w = try World()
        try await w.captureBoth()
        try w.writeSession(account: "B", id: "local_1")
        try w.writeSession(account: "B", id: "local_2")
        var state = try w.env.store.load()
        state.sharedSessionIds = ["local_1"]
        try w.env.store.save(state)
        let result = try await Switcher(env: w.env).switchTo("A")
        #expect(result.sharedSessionIds == ["local_1"])
        let target = w.support.appendingPathComponent("claude-code-sessions/A/org-A")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("local_1.json").path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("local_2.json").path))
    }

    @Test func shareAllSharesEverySession() async throws {
        let w = try World()
        try await w.captureBoth()
        try w.writeSession(account: "B", id: "local_1")
        try w.writeSession(account: "B", id: "local_2")
        var state = try w.env.store.load()
        state.shareAll = true
        try w.env.store.save(state)
        let result = try await Switcher(env: w.env).switchTo("A")
        #expect(Set(result.sharedSessionIds) == ["local_1", "local_2"])
    }

    @Test func failureDuringDesktopApplyRestoresEverything() async throws {
        let w = try World()
        try await w.captureBoth()
        let jsonBefore = try Data(contentsOf: w.claudeJSONURL)
        w.desktopLogin = FailingApplyLogin(inner: w.realLogin)
        await #expect {
            _ = try await Switcher(env: w.env).switchTo("A")
        } throws: { error in
            if case SwitchError.stepFailed(step: "apply Desktop login", _) = error { return true }
            return false
        }
        #expect(try w.liveToken() == "tok-B")
        #expect(try Data(contentsOf: w.claudeJSONURL) == jsonBefore)
        #expect(try w.cookies() == "cookies-B")
        #expect(try w.env.store.load().activeId == "B")
        #expect(w.desktop.isRunning)
    }

    @Test func desktopRelaunchedOnlyIfItWasRunning() async throws {
        let w = try World(desktopRunning: false)
        try await w.captureBoth()
        _ = try await Switcher(env: w.env).switchTo("A")
        #expect(w.desktop.launches == 0)

        let running = try World(desktopRunning: true)
        try await running.captureBoth()
        let before = running.desktop.launches
        _ = try await Switcher(env: running.env).switchTo("A")
        #expect(running.desktop.launches == before + 1)
        #expect(running.desktop.isRunning)
    }
}
