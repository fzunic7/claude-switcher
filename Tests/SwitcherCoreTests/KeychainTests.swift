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
        try SecurityCLIStore(runner: runner).write(service: "Claude Code-credentials", account: "unknown", secret: Data("ab".utf8))
        let call = try #require(runner.calls.first)
        #expect(call.args == ["-i"])
        #expect(call.stdin == "add-generic-password -U -s \"Claude Code-credentials\" -a \"unknown\" -X 6162\n")
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
