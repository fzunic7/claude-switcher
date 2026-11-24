import Foundation
import Testing
@testable import SwitcherCore

final class FakeLister: KeychainServiceListing, @unchecked Sendable {
    var services: Set<String> = []
    func services(withPrefix prefix: String) throws -> Set<String> { services.filter { $0.hasPrefix(prefix) } }
}

@Suite struct IsolatedSignInTests {
    func setup() throws -> (dir: URL, secrets: InMemorySecretStore, lister: FakeLister, signIn: IsolatedSignIn) {
        let dir = try makeTempDir().appendingPathComponent("adding")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secrets = InMemorySecretStore(), lister = FakeLister()
        lister.services = [ServiceNames.claudeCode]
        let signIn = try IsolatedSignIn(folder: dir, secrets: secrets, lister: lister)
        return (dir, secrets, lister, signIn)
    }

    @Test func notFinishedYet() throws {
        let (_, _, _, signIn) = try setup()
        #expect(try signIn.collect() == nil)
    }

    @Test func collectsTheNewLoginAndCleansUp() throws {
        let (dir, secrets, lister, signIn) = try setup()
        // What `CLAUDE_CONFIG_DIR=dir claude auth login` leaves behind:
        try Data(#"{"oauthAccount":{"accountUuid":"C","organizationUuid":"org-C","emailAddress":"carol@x"}}"#.utf8)
            .write(to: dir.appendingPathComponent(".claude.json"))
        lister.services.insert("Claude Code-credentials-1a2b3c4d")
        try secrets.write(service: "Claude Code-credentials-1a2b3c4d", account: "me", secret: Data("tok-C".utf8))

        let login = try #require(try signIn.collect())
        #expect(login.account["accountUuid"] == .string("C"))
        #expect(login.secret == Data("tok-C".utf8))
        #expect(try secrets.read(service: "Claude Code-credentials-1a2b3c4d") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func liveLoginIsNeverTouched() throws {
        let (dir, secrets, lister, signIn) = try setup()
        try secrets.write(service: ServiceNames.claudeCode, account: "me", secret: Data("tok-live".utf8))
        try Data(#"{"oauthAccount":{"accountUuid":"C","emailAddress":"carol@x"}}"#.utf8).write(to: dir.appendingPathComponent(".claude.json"))
        lister.services.insert("Claude Code-credentials-ffff")
        try secrets.write(service: "Claude Code-credentials-ffff", account: "me", secret: Data("tok-C".utf8))
        _ = try signIn.collect()
        #expect(try secrets.read(service: ServiceNames.claudeCode)?.secret == Data("tok-live".utf8))
    }

    @Test func launchesClaudeWithItsOwnConfigFolder() throws {
        let (dir, _, _, signIn) = try setup()
        #expect(signIn.environment["CLAUDE_CONFIG_DIR"] == dir.path)
        #expect(LoginLauncher.terminalScript(claudePath: "/bin/claude", configDir: "/tmp/a b").contains("CLAUDE_CONFIG_DIR="))
    }
}

@Suite struct AddProfileTests {
    @Test func addingDoesNotChangeTheLiveLoginOrActiveAccount() async throws {
        let w = try World()
        try await w.captureBoth()                                     // B live and active
        let before = try Data(contentsOf: w.claudeJSONURL)
        let p = try Switcher(env: w.env).addProfile(
            account: ["accountUuid": .string("C"), "organizationUuid": .string("org-C"), "emailAddress": .string("carol@x")],
            login: Data("tok-C".utf8))
        #expect(p.id == "C" && p.label == "carol" && p.role == .backup)
        #expect(try w.liveToken() == "tok-B")
        #expect(try Data(contentsOf: w.claudeJSONURL) == before)
        #expect(try w.vaultToken("C") == "tok-C")
        #expect(try w.env.store.load().activeId == "B")
    }

    @Test func reAddingAnExistingAccountRefreshesItsSavedLogin() async throws {
        let w = try World()
        try await w.captureBoth()
        _ = try Switcher(env: w.env).addProfile(account: ["accountUuid": .string("A"), "emailAddress": .string("A@x")],
                                                login: Data("tok-A-new".utf8))
        #expect(try w.vaultToken("A") == "tok-A-new")
        let state = try w.env.store.load()
        #expect(state.profiles.count == 2)
        #expect(state.profile("A")?.label == "Main")
    }
}

@Suite struct IsolatedSignInMoreTests {
    @Test func realKeychainListerSeesANewItem() throws {
        let service = "ClaudeSwitcher.test-list-\(UUID().uuidString)"
        defer { deleteAll(service) }
        let lister = SecurityKeychainLister()
        #expect(try !lister.services(withPrefix: service).contains(service))
        _ = try ProcessRunner().run("/usr/bin/security", ["add-generic-password", "-s", service, "-a", "x", "-w", "v"])
        #expect(try lister.services(withPrefix: service) == [service])
    }

    @Test func loginStoredAsAFileIsPickedUpToo() throws {
        let dir = try makeTempDir().appendingPathComponent("adding")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let signIn = try IsolatedSignIn(folder: dir, secrets: InMemorySecretStore(), lister: FakeLister())
        try Data(#"{"oauthAccount":{"accountUuid":"C","emailAddress":"carol@x"}}"#.utf8).write(to: dir.appendingPathComponent(".claude.json"))
        try Data("tok-file".utf8).write(to: dir.appendingPathComponent(".credentials.json"))
        let login = try #require(try signIn.collect())
        #expect(login.secret == Data("tok-file".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
