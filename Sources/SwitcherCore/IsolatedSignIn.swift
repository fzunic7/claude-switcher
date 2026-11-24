import Foundation

public protocol KeychainServiceListing: Sendable {
    func services(withPrefix prefix: String) throws -> Set<String>
}

/// Lists Keychain item service names (attributes only; no secrets are read).
public struct SecurityKeychainLister: KeychainServiceListing {
    let runner: CommandRunner
    public init(runner: CommandRunner = ProcessRunner()) { self.runner = runner }

    public func services(withPrefix prefix: String) throws -> Set<String> {
        let result = try runner.run("/usr/bin/security", ["dump-keychain"])
        let text = String(decoding: result.stdout, as: UTF8.self)
        let marker = "\"svce\"<blob>=\""
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: marker) else { continue }
            let rest = line[r.upperBound...]
            guard let end = rest.lastIndex(of: "\"") else { continue }
            let name = String(rest[..<end])
            if name.hasPrefix(prefix) { names.insert(name) }
        }
        return names
    }
}

/// Signs in to another account without touching the current one: Claude Code runs with its own private
/// config folder (`CLAUDE_CONFIG_DIR`), so its login lands in a separate Keychain item and account file.
/// `collect()` picks both up, then removes them.
public final class IsolatedSignIn: @unchecked Sendable {
    static let credentialsPrefix = "Claude Code-credentials"

    public let folder: URL
    let secrets: SecretStore
    let lister: KeychainServiceListing
    let before: Set<String>

    public init(folder: URL, secrets: SecretStore, lister: KeychainServiceListing) throws {
        self.folder = folder; self.secrets = secrets; self.lister = lister
        try FileSystem.ensurePrivateDirectory(folder)
        before = try lister.services(withPrefix: Self.credentialsPrefix)
    }

    public var environment: [String: String] { ["CLAUDE_CONFIG_DIR": folder.path] }

    /// The new account and its login once the sign-in has finished; nil while still waiting.
    public func collect() throws -> (account: [String: JSONValue], secret: Data)? {
        guard let account = try? ClaudeJSON(url: folder.appendingPathComponent(".claude.json")).readAccount(),
              account["accountUuid"]?.stringValue != nil else { return nil }
        let created = try lister.services(withPrefix: Self.credentialsPrefix).subtracting(before)
        if let service = created.sorted().first, let item = try secrets.read(service: service) {
            discard(created: created)
            return (account, item.secret)
        }
        // Claude Code can also keep the login in a file inside its config folder.
        if let file = try? Data(contentsOf: folder.appendingPathComponent(".credentials.json")), !file.isEmpty {
            discard(created: created)
            return (account, file)
        }
        return nil
    }

    /// Removes the temporary folder and any login the sign-in created.
    public func discard() {
        discard(created: (try? lister.services(withPrefix: Self.credentialsPrefix).subtracting(before)) ?? [])
    }

    private func discard(created: Set<String>) {
        for service in created where service != ServiceNames.claudeCode { try? secrets.delete(service: service) }
        try? FileManager.default.removeItem(at: folder)
    }
}
