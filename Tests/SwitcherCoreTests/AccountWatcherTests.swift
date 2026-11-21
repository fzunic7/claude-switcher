import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AccountWatcherTests {
    func signInFresh(_ w: World, _ id: String, email: String) throws {
        let json = #"{"oauthAccount":{"accountUuid":"\#(id)","organizationUuid":"org-\#(id)","emailAddress":"\#(email)"}}"#
        try Data(json.utf8).write(to: w.claudeJSONURL)
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-\(id)".utf8))
        w.identity.emails[id] = email
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
        #expect(try await watcher.check() == .activeChanged("B"))
        #expect(!watcher.isAdding)
        #expect(try w.env.store.load().activeId == "B")
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
        #expect(try await watcher.check() == .activeChanged("A"))
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

@Suite struct AccountWatcherReviewTests {
    func writeAccount(_ w: World, _ id: String?) throws {
        let json = id.map { #"{"oauthAccount":{"accountUuid":"\#($0)","organizationUuid":"org-\#($0)","emailAddress":"\#($0)@x"}}"# } ?? #"{"numStartups":1}"#
        try Data(json.utf8).write(to: w.claudeJSONURL)
    }

    @Test func halfWrittenLoginIsNotCaptured() async throws {
        let w = try World()
        try await w.captureBoth()
        _ = try await Switcher(env: w.env).switchTo("A")       // live: A, token tok-A
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        try writeAccount(w, "C")                                // .claude.json updated, Keychain still A's
        #expect(try await watcher.check() == .none)
        #expect(try w.env.store.load().profile("C") == nil)
        #expect(try w.vaultToken("C") == nil)
        #expect(watcher.isAdding)
    }

    @Test func noCaptureWhileSignInProcessStillRunning() async throws {
        let w = try World()
        try await w.captureBoth()
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        watcher.signInInProgress = true
        try writeAccount(w, "C")
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-C".utf8))
        #expect(try await watcher.check() == .none)
        watcher.signInInProgress = false
        guard case .addedAndRestored = try await watcher.check() else { Issue.record("expected add after exit"); return }
    }

    @Test func liveSavedAccountBecomesActive() async throws {
        let w = try World()
        try await w.captureBoth()                               // activeId B
        try writeAccount(w, "A")
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-A".utf8))
        #expect(try await AccountWatcher(env: w.env).check() == .activeChanged("A"))
        #expect(try w.env.store.load().activeId == "A")
    }

    @Test func abandonAddRestoresPreviousWhenLoginWasRemoved() async throws {
        let w = try World()
        try await w.captureBoth()                               // B live
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        try w.secrets.delete(service: ServiceNames.claudeCode)  // sign-in logged out, then was cancelled
        try writeAccount(w, nil)
        try watcher.abandonAdd()
        #expect(!watcher.isAdding)
        #expect(try w.liveToken() == "tok-B")
        #expect(try ClaudeJSON(url: w.claudeJSONURL).readAccount()?["accountUuid"] == .string("B"))
    }

    @Test func abandonAddLeavesUntouchedLoginAlone() async throws {
        let w = try World()
        try await w.captureBoth()
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()
        try watcher.abandonAdd()
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func switchToActiveWithMissingLiveLoginRestoresIt() async throws {
        let w = try World()
        try await w.captureBoth()                               // activeId B
        try w.secrets.delete(service: ServiceNames.claudeCode)
        try writeAccount(w, nil)
        _ = try await Switcher(env: w.env).switchTo("B")
        #expect(try w.liveToken() == "tok-B")
    }

    @Test func removeProfileRejectsEmptyId() async throws {
        let w = try World()
        try await w.captureBoth()
        #expect(throws: SwitchError.self) { try Switcher(env: w.env).removeProfile("") }
        #expect(w.realLogin.hasSnapshot("A") && w.realLogin.hasSnapshot("B"))
    }
}


/// The account file (`~/.claude.json`) is rewritten by running Claude Code processes and can name a different
/// account than the login in the Keychain. Identity must come from `claude auth status`.
@Suite struct RealIdentityTests {
    func writeAccountFile(_ w: World, _ id: String) throws {
        try Data(#"{"oauthAccount":{"accountUuid":"\#(id)","organizationUuid":"org-\#(id)","emailAddress":"\#(id)@x"}}"#.utf8)
            .write(to: w.claudeJSONURL)
    }

    @Test func accountFileDisagreeingWithLiveLoginIsNotCaptured() async throws {
        let w = try World()
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-A".utf8))
        try writeAccountFile(w, "B")                                // a running claude wrote B back
        #expect(try await AccountWatcher(env: w.env).check() == .none)
        #expect(try w.env.store.load().profiles.isEmpty)
        #expect(try w.vaultToken("B") == nil)
    }

    @Test func loginSavedUnderWrongAccountIsRepaired() async throws {
        let w = try World()
        // The bug's aftermath: "frane" (F) holds X's login; X is live and the account file agrees.
        var state = SwitcherState()
        state.profiles = [Profile(id: "F", label: "frane", role: .main, orgUuid: "org-F", email: "F@x",
                                  oauthAccount: ["accountUuid": .string("F")], hasDesktopSnapshot: false)]
        state.activeId = "F"
        try w.env.store.save(state)
        try w.secrets.write(service: ServiceNames.vault("F"), account: "unknown", secret: Data("tok-X".utf8))
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-X".utf8))
        try writeAccountFile(w, "X")
        let event = try await AccountWatcher(env: w.env).check()
        guard case .added(let p) = event else { Issue.record("expected X to be added, got \(event)"); return }
        #expect(p.id == "X")
        #expect(try w.vaultToken("X") == "tok-X")
        #expect(try w.vaultToken("F") == nil)                       // wrong copy removed
        #expect(try w.env.store.load().activeId == "X")
    }

    @Test func knownAccountsSavedLoginIsRefreshedFromVerifiedLiveLogin() async throws {
        let w = try World()
        try await w.captureBoth()                                   // B live
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-B-renewed".utf8))
        _ = try await AccountWatcher(env: w.env).check()
        #expect(try w.vaultToken("B") == "tok-B-renewed")
    }

    @Test func knownAccountIdentifiedByEmailEvenWhenAccountFileIsStale() async throws {
        let w = try World()
        try await w.captureBoth()                                   // B live, active B
        try w.secrets.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("tok-A-new".utf8))
        // account file still says B
        #expect(try await AccountWatcher(env: w.env).check() == .activeChanged("A"))
        #expect(try w.vaultToken("A") == "tok-A-new")
        #expect(try w.vaultToken("B") == "tok-B")
    }

    @Test func switchUsesLiveIdentityNotAccountFile() async throws {
        let w = try World()
        try await w.captureBoth()                                   // B live
        try writeAccountFile(w, "A")                                // stale: file says A, Keychain is B
        let result = try await Switcher(env: w.env).switchTo("A")   // must not say "already active"
        #expect(result.to == "A")
        #expect(try w.liveToken() == "tok-A")
        #expect(try w.vaultToken("B") == "tok-B")
    }

    @Test func noIdentityMeansNoCapture() async throws {
        let w = try World()
        try w.signIn("A", token: "tok-A")
        w.identity.failing = true
        #expect(try await AccountWatcher(env: w.env).check() == .none)
        #expect(try w.env.store.load().profiles.isEmpty)
    }
}

@Suite struct ReAddTests {
    @Test func addAccountReAddsARemovedLiveAccount() async throws {
        let w = try World()
        try await w.captureBoth()                                // B live
        try Switcher(env: w.env).removeProfile("B")              // ignored while live
        let watcher = AccountWatcher(env: w.env)
        try watcher.beginAdd()                                   // the user explicitly adds it again
        guard case .added(let p) = try await watcher.check() else { Issue.record("B should be re-added"); return }
        #expect(p.id == "B")
        #expect(try w.env.store.load().ignoredAccountId == nil)
    }
}
