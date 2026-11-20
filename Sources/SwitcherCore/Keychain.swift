import Foundation

public enum ServiceNames {
    public static let claudeCode = "Claude Code-credentials"
    public static func vault(_ accountUuid: String) -> String { "ClaudeSwitcher.\(accountUuid)" }
    /// The vault copy as it was before the most recent save-back, so a wrong save can be undone.
    public static func vaultPrevious(_ accountUuid: String) -> String { "ClaudeSwitcher.\(accountUuid).prev" }
}

public enum KeychainError: Error, Equatable {
    case commandFailed(status: Int32)
    case invalidName(String)
    case verificationFailed
}

public protocol SecretStore: Sendable {
    func read(service: String) throws -> (account: String, secret: Data)?
    func write(service: String, account: String, secret: Data) throws
    func delete(service: String) throws
}

/// Keychain access through `/usr/bin/security`, whose binary is already trusted by the
/// Claude Code item's ACL. Secrets are written via `security -i` on stdin, never as arguments.
public struct SecurityCLIStore: SecretStore {
    static let tool = "/usr/bin/security"
    static let notFound: Int32 = 44
    static let interactiveLineLimit = 3500
    let runner: CommandRunner

    public init(runner: CommandRunner = ProcessRunner()) { self.runner = runner }

    public func read(service: String) throws -> (account: String, secret: Data)? {
        let attrs = try runner.run(Self.tool, ["find-generic-password", "-s", service])
        if attrs.status == Self.notFound { return nil }
        guard attrs.status == 0 else { throw KeychainError.commandFailed(status: attrs.status) }
        let account = Self.parseAccount(String(decoding: attrs.stdout, as: UTF8.self)) ?? ""
        let pw = try runner.run(Self.tool, ["find-generic-password", "-s", service, "-w"])
        if pw.status == Self.notFound { return nil }
        guard pw.status == 0 else { throw KeychainError.commandFailed(status: pw.status) }
        var secret = pw.stdout
        if secret.last == UInt8(ascii: "\n") { secret.removeLast() }
        return (account, secret)
    }

    public func write(service: String, account: String, secret: Data) throws {
        for name in [service, account] where name.contains("\"") || name.contains("\n") {
            throw KeychainError.invalidName(name)
        }
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -X \(hex)\n"
        let result: (status: Int32, stdout: Data)
        if command.utf8.count <= Self.interactiveLineLimit {
            result = try runner.run(Self.tool, ["-i"], stdin: Data(command.utf8))
        } else {
            // `security -i` splits lines over ~4 KB and runs the first half; pass long secrets as arguments.
            result = try runner.run(Self.tool, ["add-generic-password", "-U", "-s", service, "-a", account, "-X", hex])
        }
        guard result.status == 0 else { throw KeychainError.commandFailed(status: result.status) }
        guard try read(service: service)?.secret == secret else { throw KeychainError.verificationFailed }
    }

    public func delete(service: String) throws {
        let result = try runner.run(Self.tool, ["delete-generic-password", "-s", service])
        guard result.status == 0 || result.status == Self.notFound else {
            throw KeychainError.commandFailed(status: result.status)
        }
    }

    static func parseAccount(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"acct\"<blob>=\"") else { continue }
            return String(trimmed.dropFirst("\"acct\"<blob>=\"".count).dropLast())
        }
        return nil
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: (String, Data)] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(service: String) throws -> (account: String, secret: Data)? {
        lock.withLock { items[service].map { ($0.0, $0.1) } }
    }

    public func write(service: String, account: String, secret: Data) throws {
        lock.withLock { items[service] = (account, secret) }
    }

    public func delete(service: String) throws {
        lock.withLock { _ = items.removeValue(forKey: service) }
    }
}
