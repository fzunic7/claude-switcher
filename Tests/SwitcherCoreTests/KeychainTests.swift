import Foundation
import Testing
@testable import SwitcherCore

final class RecordingRunner: CommandRunner, @unchecked Sendable {
    var calls: [(path: String, args: [String], stdin: String?)] = []
    var responses: [(Int32, String)] = []

    func run(_ path: String, _ args: [String], stdin: Data?) throws -> (status: Int32, stdout: Data) {
        calls.append((path, args, stdin.map { String(decoding: $0, as: UTF8.self) }))
        let r = responses.isEmpty ? (0, "") : responses.removeFirst()
        return (r.0, Data(r.1.utf8))
    }
}

@Suite struct KeychainTests {
    let attrs = """
    keychain: "/Users/me/Library/Keychains/login.keychain-db"
    attributes:
        "acct"<blob>="unknown"
        "svce"<blob>="Claude Code-credentials"
    """

    @Test func readParsesAcctAndPassword() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, attrs), (0, "{\"token\":\"t\"}\n")]
        let result = try SecurityCLIStore(runner: runner).read(service: ServiceNames.claudeCode)
        #expect(result?.account == "unknown")
        #expect(result?.secret == Data("{\"token\":\"t\"}".utf8))
        #expect(runner.calls[0].args == ["find-generic-password", "-s", "Claude Code-credentials"])
        #expect(runner.calls[1].args == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        #expect(runner.calls.allSatisfy { $0.path == "/usr/bin/security" })
    }

    @Test func readReturnsNilOnStatus44() throws {
        let runner = RecordingRunner()
        runner.responses = [(44, "")]
        #expect(try SecurityCLIStore(runner: runner).read(service: "missing") == nil)
    }

    @Test func readThrowsOnOtherFailure() {
        let runner = RecordingRunner()
        runner.responses = [(51, "")]
        #expect(throws: KeychainError.self) { try SecurityCLIStore(runner: runner).read(service: "x") }
    }

    @Test func writeUsesUpdateFlagViaStdinNotArgs() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, ""), (0, attrs), (0, "ab\n")]
        try SecurityCLIStore(runner: runner).write(service: "Claude Code-credentials", account: "unknown", secret: Data("ab".utf8))
        let call = try #require(runner.calls.first)
        #expect(call.args == ["-i"])
        #expect(call.stdin == "add-generic-password -U -s \"Claude Code-credentials\" -a \"unknown\" -X 6162\n")
    }

    @Test func longSecretFallsBackToArgumentsNotInteractiveMode() throws {
        let secret = Data(repeating: UInt8(ascii: "x"), count: 3000)
        let runner = RecordingRunner()
        runner.responses = [(0, ""), (0, attrs), (0, String(repeating: "x", count: 3000))]
        try SecurityCLIStore(runner: runner).write(service: "svc", account: "unknown", secret: secret)
        let call = try #require(runner.calls.first)
        #expect(call.args.prefix(7) == ["add-generic-password", "-U", "-s", "svc", "-a", "unknown", "-X"])
        #expect(call.stdin == nil)
    }

    @Test func writeVerifiesReadBack() {
        let runner = RecordingRunner()
        runner.responses = [(0, ""), (0, attrs), (0, "truncated")]
        #expect(throws: KeychainError.verificationFailed) {
            try SecurityCLIStore(runner: runner).write(service: "svc", account: "unknown", secret: Data("full".utf8))
        }
    }

    @Test func realKeychainRoundTripsLongSecret() throws {
        let store = SecurityCLIStore(runner: ProcessRunner())
        let service = "ClaudeSwitcher.test-\(UUID().uuidString)"
        defer { try? store.delete(service: service) }
        let secret = Data((0..<3000).map { _ in UInt8.random(in: 0x21...0x7e) })
        try store.write(service: service, account: "unknown", secret: secret)
        #expect(try store.read(service: service)?.secret == secret)
    }

    @Test func writeRejectsQuotesInNames() {
        #expect(throws: KeychainError.self) {
            try SecurityCLIStore(runner: RecordingRunner()).write(service: "a\"b", account: "x", secret: Data())
        }
    }

    @Test func vaultServiceName() {
        #expect(ServiceNames.vault("abc") == "ClaudeSwitcher.abc")
    }

    @Test func inMemoryStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        try store.write(service: "s", account: "a", secret: Data("x".utf8))
        #expect(try store.read(service: "s")?.secret == Data("x".utf8))
        try store.delete(service: "s")
        #expect(try store.read(service: "s") == nil)
    }
}

@Suite struct KeychainAccountTests {
    let attrs = """
    attributes:
        "acct"<blob>="frane"
        "svce"<blob>="Claude Code-credentials"
    """

    @Test func readUsesTheConfiguredAccount() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, attrs), (0, "real\n")]
        let store = SecurityCLIStore(runner: runner, accounts: [ServiceNames.claudeCode: "frane"])
        #expect(try store.read(service: ServiceNames.claudeCode)?.secret == Data("real".utf8))
        #expect(runner.calls[0].args == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "frane"])
        #expect(runner.calls[1].args == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "frane", "-w"])
    }

    @Test func writeUsesTheConfiguredAccountWhateverIsPassed() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, ""), (0, attrs), (0, "ab\n")]
        let store = SecurityCLIStore(runner: runner, accounts: [ServiceNames.claudeCode: "frane"])
        try store.write(service: ServiceNames.claudeCode, account: "unknown", secret: Data("ab".utf8))
        #expect(runner.calls[0].stdin == "add-generic-password -U -s \"Claude Code-credentials\" -a \"frane\" -X 6162\n")
    }

    @Test func liveStoreUsesTheMacUserNameForClaudeCode() {
        #expect(SecurityCLIStore.live().accounts[ServiceNames.claudeCode] == NSUserName())
    }

    @Test func realKeychainPicksTheRightOfTwoSameNamedItems() throws {
        let service = "ClaudeSwitcher.test-\(UUID().uuidString)"
        let plain = SecurityCLIStore(runner: ProcessRunner())
        let scoped = SecurityCLIStore(runner: ProcessRunner(), accounts: [service: "real-user"])
        defer { deleteAll(service) }
        try plain.write(service: service, account: "stub", secret: Data("stub".utf8))
        try scoped.write(service: service, account: "ignored", secret: Data("real".utf8))
        #expect(try scoped.read(service: service)?.secret == Data("real".utf8))
    }
}


/// Removes every Keychain item for a test service, whatever its account name.
func deleteAll(_ service: String) {
    for _ in 0..<10 {
        guard let r = try? ProcessRunner().run("/usr/bin/security", ["delete-generic-password", "-s", service]), r.status == 0 else { return }
    }
}

@Suite struct OwnItemTests {
    func count(_ service: String, account: String) -> Bool {
        (try? ProcessRunner().run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account]))?.status == 0
    }

    @Test func realKeychainWriteReplacesOlderCopiesOfOwnItems() throws {
        let service = "ClaudeSwitcher.test-\(UUID().uuidString)"
        defer { deleteAll(service) }
        _ = try ProcessRunner().run("/usr/bin/security", ["add-generic-password", "-s", service, "-a", "unknown", "-w", "old"])
        let store = SecurityCLIStore(runner: ProcessRunner())
        try store.write(service: service, account: "frane", secret: Data("new".utf8))
        #expect(try store.read(service: service)?.secret == Data("new".utf8))
        #expect(!count(service, account: "unknown"))
        #expect(!count(service, account: "frane"))
        #expect(count(service, account: SecurityCLIStore.ownAccount))
    }

    @Test func realKeychainReadsLegacyCopyWhenNoCurrentOne() throws {
        let service = "ClaudeSwitcher.test-\(UUID().uuidString)"
        defer { deleteAll(service) }
        _ = try ProcessRunner().run("/usr/bin/security", ["add-generic-password", "-s", service, "-a", "unknown", "-w", "legacy"])
        #expect(try SecurityCLIStore(runner: ProcessRunner()).read(service: service)?.secret == Data("legacy".utf8))
    }

    @Test func realKeychainDeleteRemovesEveryCopy() throws {
        let service = "ClaudeSwitcher.test-\(UUID().uuidString)"
        defer { deleteAll(service) }
        _ = try ProcessRunner().run("/usr/bin/security", ["add-generic-password", "-s", service, "-a", "unknown", "-w", "a"])
        _ = try ProcessRunner().run("/usr/bin/security", ["add-generic-password", "-s", service, "-a", "frane", "-w", "b"])
        try SecurityCLIStore(runner: ProcessRunner()).delete(service: service)
        #expect(try SecurityCLIStore(runner: ProcessRunner()).read(service: service) == nil)
    }
}
