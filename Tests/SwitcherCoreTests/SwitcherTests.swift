import Foundation
import Testing
@testable import SwitcherCore

final class FakeDesktop: DesktopAppControl, @unchecked Sendable {
    var isRunning: Bool
    var quits = 0, launches = 0
    var onQuit: () throws -> Void = {}
    init(running: Bool) { isRunning = running }
    func quit() async throws { quits += 1; isRunning = false; try onQuit() }
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

struct FailingCaptureLogin: DesktopLoginStore {
    let inner: DesktopLoginFiles
    func capture(into id: String) throws { throw CocoaError(.fileWriteOutOfSpace) }
    func hasSnapshot(_ id: String) -> Bool { inner.hasSnapshot(id) }
    func apply(from id: String) throws { try inner.apply(from: id) }
    func backupCurrent() throws -> URL { try inner.backupCurrent() }
    func restore(from backup: URL) throws { try inner.restore(from: backup) }
}

struct FailingApplyAndRestoreLogin: DesktopLoginStore {
    let inner: DesktopLoginFiles
    let backups: URL
    func capture(into id: String) throws { try inner.capture(into: id) }
    func hasSnapshot(_ id: String) -> Bool { inner.hasSnapshot(id) }
    func apply(from id: String) throws { throw CocoaError(.fileWriteUnknown) }
    func backupCurrent() throws -> URL { try inner.backupCurrent() }
    func restore(from backup: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

final class FakeDesktopAccount: DesktopAccountReading, @unchecked Sendable {
    var id: String?
    var modifiedAt = Date()
    func signedInAccount() -> (id: String, modifiedAt: Date)? { id.map { ($0, modifiedAt) } }
}

/// Mimics `claude auth status`: reports the owner of whatever token is in the live Keychain item.
/// Test tokens look like "tok-<id>" or "tok-<id>-<suffix>".
final class FakeIdentity: LiveIdentity, @unchecked Sendable {
    let secrets: SecretStore
    var emails: [String: String] = [:]
    var failing = false
    init(secrets: SecretStore) { self.secrets = secrets }
    func current() throws -> LiveLogin? {
        if failing { throw SwitchError.stepFailed(step: "auth status", underlying: "boom") }
        guard let secret = try secrets.read(service: ServiceNames.claudeCode)?.secret else { return nil }
        let token = String(decoding: secret, as: UTF8.self)
        guard token.hasPrefix("tok-") else { return nil }
        let id = String(token.dropFirst(4).split(separator: "-").first ?? "")
        return LiveLogin(email: emails[id] ?? "\(id)@x", orgId: "org-\(id)")
    }
}

/// Two accounts, A (main) and B (backup), on a temp filesystem with an in-memory keychain.
final class World {
    let base: URL
    let secrets = InMemorySecretStore()
    let desktop: FakeDesktop
    let desktopAccount = FakeDesktopAccount()
    lazy var identity = FakeIdentity(secrets: secrets)
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
                            desktop: desktop, desktopAccount: desktopAccount, identity: identity)
    }

    func signIn(_ id: String, token: String) throws {
        let json = #"{"numStartups":7,"oauthAccount":{"accountUuid":"\#(id)","organizationUuid":"org-\#(id)","emailAddress":"\#(id)@x"}}"#
        try Data(json.utf8).write(to: claudeJSONURL)
        try secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data(token.utf8))
        try Data("cookies-\(id)".utf8).write(to: support.appendingPathComponent("Cookies"))
        desktopAccount.id = id
        desktopAccount.modifiedAt = Date()
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
        #expect(result.warnings == ["Sign in to Claude Desktop once as Main; the app remembers it after that."])
        #expect(try w.cookies() == "cookies-B")
        #expect(try w.liveToken() == "tok-A")
    }

    @Test func switchMergesSessionsBothWays() async throws {
        let w = try World()
        try await w.captureBoth()
        try w.writeSession(account: "B", id: "local_1")
        try w.writeSession(account: "A", id: "local_2")
        let result = try await Switcher(env: w.env).switchTo("A")
        #expect(result.sharedSessionIds == ["local_1"])
        let root = w.support.appendingPathComponent("claude-code-sessions")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/org-A/local_1.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/org-B/local_2.json").path))
    }

    @Test func desktopLoginSavedUnderDesktopsAccountNotCLIs() async throws {
        let w = try World()
        try await w.captureBoth()                       // CLI and Desktop on B
        w.desktopAccount.id = "A"                       // user signed Desktop into A by hand
        try Data("cookies-A-live".utf8).write(to: w.support.appendingPathComponent("Cookies"))
        _ = try await Switcher(env: w.env).switchTo("A")
        let vault = w.base.appendingPathComponent("switcher/vault")
        func snap(_ id: String) throws -> String {
            String(decoding: try Data(contentsOf: vault.appendingPathComponent("\(id)/desktop/Cookies")), as: UTF8.self)
        }
        #expect(try snap("A") == "cookies-A-live")
        #expect(try snap("B") == "cookies-B")
    }

    @Test func staleDesktopConfigUsesSwitcherRecord() async throws {
        let w = try World()
        try await w.captureBoth()
        w.desktopAccount.modifiedAt = Date(timeIntervalSince1970: 1_000)   // config untouched since long ago, says B
        _ = try await Switcher(env: w.env).switchTo("A")                    // applies A's Desktop login
        try Data("cookies-A-used".utf8).write(to: w.support.appendingPathComponent("Cookies"))
        _ = try await Switcher(env: w.env).switchTo("B")                    // config still says B (stale)
        let snapA = w.base.appendingPathComponent("switcher/vault/A/desktop/Cookies")
        #expect(String(decoding: try Data(contentsOf: snapA), as: UTF8.self) == "cookies-A-used")
        #expect(try w.cookies() == "cookies-B")
        let state = try w.env.store.load()
        #expect(state.desktopAccountId == "B")
    }

    @Test func desktopLoginNotSavedWhenDesktopAccountUnknown() async throws {
        let w = try World()
        try await w.captureBoth()
        w.desktopAccount.id = "Z"
        try Data("cookies-Z".utf8).write(to: w.support.appendingPathComponent("Cookies"))
        _ = try await Switcher(env: w.env).switchTo("A")
        let vault = w.base.appendingPathComponent("switcher/vault")
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("Z").path))
        #expect(String(decoding: try Data(contentsOf: vault.appendingPathComponent("B/desktop/Cookies")), as: UTF8.self) == "cookies-B")
    }

    @Test func switchStoresClaudeCodeUsageCacheForAccountLeft() async throws {
        let w = try World()
        try await w.captureBoth()
        let json = #"{"oauthAccount":{"accountUuid":"B","organizationUuid":"org-B","emailAddress":"B@x"},"cachedUsageUtilization":{"fetchedAtMs":1700000000000,"accountUuid":"B","utilization":{"five_hour":{"utilization":88,"resets_at":null}}}}"#
        try Data(json.utf8).write(to: w.claudeJSONURL)
        _ = try await Switcher(env: w.env).switchTo("A")
        let state = try w.env.store.load()
        #expect(state.lastUsage["B"]?.session?.utilization == 88)
        #expect(state.lastUsage["B"]?.isLive == false)
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

    @Test func staleAccountFileDoesNotFoolTheSwitch() async throws {
        let w = try World()
        try await w.captureBoth()
        // ~/.claude.json says B (a running claude wrote it), but the live login is A's.
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-A".utf8))
        await #expect(throws: SwitchError.alreadyActive) { _ = try await Switcher(env: w.env).switchTo("A") }
        #expect(try w.vaultToken("B") == "tok-B")
        #expect(try w.vaultToken("A") == "tok-A")
    }

    @Test func saveBackKeepsPreviousVaultCopy() async throws {
        let w = try World()
        try await w.captureBoth()
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-B-2".utf8))
        _ = try await Switcher(env: w.env).switchTo("A")
        let prev = try w.secrets.read(service: ServiceNames.vaultPrevious("B")).map { String(decoding: $0.secret, as: UTF8.self) }
        #expect(prev == "tok-B")
        #expect(try w.vaultToken("B") == "tok-B-2")
    }

    @Test func desktopCaptureFailureRelaunchesDesktopAndChangesNothing() async throws {
        let w = try World()
        try await w.captureBoth()
        w.desktopLogin = FailingCaptureLogin(inner: w.realLogin)
        await #expect {
            _ = try await Switcher(env: w.env).switchTo("A")
        } throws: { error in
            if case SwitchError.stepFailed(step: "save Desktop login", _) = error { return true }
            return false
        }
        #expect(w.desktop.isRunning)
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func rollbackFailureIsReportedAndBackupKept() async throws {
        let w = try World()
        try await w.captureBoth()
        w.desktopLogin = FailingApplyAndRestoreLogin(inner: w.realLogin, backups: w.base)
        await #expect {
            _ = try await Switcher(env: w.env).switchTo("A")
        } throws: { error in
            guard case SwitchError.rollbackIncomplete(step: "apply Desktop login", let failures) = error else { return false }
            guard failures.count == 1, let f = failures.first, f.hasPrefix("Desktop login (backup kept at ") else { return false }
            let path = String(f.dropFirst("Desktop login (backup kept at ".count).dropLast())
            return FileManager.default.fileExists(atPath: path)
        }
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func rollbackRemovesTargetSecretWhenThereWasNoLiveLogin() async throws {
        let w = try World()
        try await w.captureBoth()
        try w.secrets.delete(service: ServiceNames.claudeCode)
        w.desktopLogin = FailingApplyLogin(inner: w.realLogin)
        await #expect(throws: SwitchError.self) { _ = try await Switcher(env: w.env).switchTo("A") }
        #expect(try w.liveToken() == nil)
    }

    @Test func stateChangedDuringSwitchIsKept() async throws {
        let w = try World()
        try await w.captureBoth()
        let store = w.env.store
        w.desktop.onQuit = {
            var s = try store.load()
            s.lastUsage["Z"] = AccountUsage(session: nil, weekly: nil, extra: nil, fetchedAt: Date(timeIntervalSince1970: 1), isLive: false)
            try store.save(s)
        }
        _ = try await Switcher(env: w.env).switchTo("A")
        let state = try store.load()
        #expect(state.lastUsage["Z"] != nil)
        #expect(state.activeId == "A")
    }
}

@Suite struct SwitcherLaunchTests {
    final class NoLaunchDesktop: DesktopAppControl, @unchecked Sendable {
        var isRunning = true
        func quit() async throws { isRunning = false }
        func launch() throws { throw CocoaError(.fileNoSuchFile) }
    }

    @Test func desktopFailingToReopenIsAWarningNotARollback() async throws {
        let w = try World()
        try await w.captureBoth()
        var env = w.env
        env.desktop = NoLaunchDesktop()
        let result = try await Switcher(env: env).switchTo("A")
        #expect(try w.liveToken() == "tok-A")
        #expect(result.warnings.contains { $0.contains("reopen Claude Desktop") })
        #expect(try w.env.store.load().activeId == "A")
    }
}
