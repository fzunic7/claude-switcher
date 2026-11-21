import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AccountWatcherTests {
    func signInFresh(_ w: World, _ id: String, email: String) throws {
        let json = #"{"oauthAccount":{"accountUuid":"\#(id)","organizationUuid":"org-\#(id)","emailAddress":"\#(email)"}}"#
        try Data(json.utf8).write(to: w.claudeJSONURL)
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-\(id)".utf8))
    }

    @Test func firstAccountIsMain() async throws {
        let w = try World()
        try signInFresh(w, "A", email: "alice@x.com")
        let event = try await AccountWatcher(env: w.env).check()
        guard case .added(let p) = event else { Issue.record("expected .added, got \(event)"); return }
        #expect(p.id == "A" && p.label == "alice" && p.role == .main)
        #expect(try w.vaultToken("A") == "tok-A")
    }

    @Test func newSignInOutsideAppIsSavedNotRestored() async throws {
        let w = try World()
        try signInFresh(w, "A", email: "alice@x.com")
        let watcher = AccountWatcher(env: w.env)
        _ = try await watcher.check()
        try signInFresh(w, "B", email: "bob@y.com")
        let event = try await watcher.check()
        guard case .added(let p) = event else { Issue.record("expected .added, got \(event)"); return }
        #expect(p.label == "bob" && p.role == .backup)
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func knownAccountIsNoEvent() async throws {
        let w = try World()
        try await w.captureBoth()
        #expect(try await AccountWatcher(env: w.env).check() == .none)
        #expect(try w.env.store.load().profiles.count == 2)
    }

    @Test func addFlowSavesAndRestoresPrevious() async throws {
        let w = try World()
        try await w.captureBoth()
        _ = try await Switcher(env: w.env).switchTo("A")
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        #expect(watcher.isAdding)
        #expect(try await watcher.check() == .none)          // still waiting, live is A
        try signInFresh(w, "C", email: "carol@z.com")
        let event = try await watcher.check()
        guard case .addedAndRestored(let added, let restored) = event else { Issue.record("got \(event)"); return }
        #expect(added.id == "C" && restored == "A")
        #expect(try w.liveToken() == "tok-A")
        #expect(try ClaudeJSON(url: w.claudeJSONURL).readAccount()?["accountUuid"] == .string("A"))
        #expect(try w.vaultToken("C") == "tok-C")
        #expect(!watcher.isAdding)
        #expect(try w.env.store.load().activeId == "A")
    }

    @Test func addFlowSavesLiveTokenOfPreviousAccountBeforeLogin() async throws {
        let w = try World()
        try await w.captureBoth()                             // B live
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-B-refreshed".utf8))
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        try signInFresh(w, "C", email: "carol@z.com")
        _ = try await watcher.check()
        #expect(try w.liveToken() == "tok-B-refreshed")
    }

    @Test func addFlowSigningIntoExistingAccountDoesNothing() async throws {
        let w = try World()
        try await w.captureBoth()
        _ = try await Switcher(env: w.env).switchTo("A")
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        try signInFresh(w, "B", email: "B@x")
        #expect(try await watcher.check() == .none)
        #expect(!watcher.isAdding)
        #expect(try w.env.store.load().profiles.count == 2)
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func cancelAddStopsWaiting() async throws {
        let w = try World()
        try await w.captureBoth()
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        watcher.cancelAdd()
        #expect(!watcher.isAdding)
    }

    @Test func removedLiveAccountIsNotReAddedUntilSwitchedAway() async throws {
        let w = try World()
        try await w.captureBoth()                             // B live
        try Switcher(env: w.env).removeProfile("B")
        let watcher = AccountWatcher(env: w.env)
        #expect(try await watcher.check() == .none)
        var state = try w.env.store.load()
        #expect(state.profiles.map(\.id) == ["A"])
        #expect(state.ignoredAccountId == "B")
        #expect(try w.vaultToken("B") == nil)

        try signInFresh(w, "A", email: "A@x")
        #expect(try await watcher.check() == .none)
        state = try w.env.store.load()
        #expect(state.ignoredAccountId == nil)

        try signInFresh(w, "B", email: "B@x")
        guard case .added = try await watcher.check() else { Issue.record("B should be re-added"); return }
    }

    @Test func switchCLIRestoresOnFailure() async throws {
        let w = try World()
        try await w.captureBoth()                             // B live
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: w.base.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.base.path) }
        #expect(throws: (any Error).self) { try Switcher(env: w.env).switchCLI(to: "A") }
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func switchCLIChangesOnlyCLI() async throws {
        let w = try World()
        try await w.captureBoth()
        let quitsBefore = w.desktop.quits
        try Switcher(env: w.env).switchCLI(to: "A")
        #expect(try w.liveToken() == "tok-A")
        #expect(try w.cookies() == "cookies-B")
        #expect(w.desktop.quits == quitsBefore)
        #expect(try w.env.store.load().activeId == "A")
    }
}
