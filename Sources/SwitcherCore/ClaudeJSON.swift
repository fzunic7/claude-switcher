import Foundation

/// Reads and replaces only the `oauthAccount` key of `~/.claude.json`, leaving everything else intact.
public struct ClaudeJSON: Sendable {
    public static let accountKey = "oauthAccount"
    public let url: URL

    public init(url: URL) { self.url = url }

    public func readAccount() throws -> [String: JSONValue]? {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: rawContents())
        guard case .object(let account)? = root[Self.accountKey] else { return nil }
        return account
    }

    /// Re-reads the file right before writing, so concurrent edits by a running `claude` survive.
    public func writeAccount(_ account: [String: JSONValue]) throws {
        let current = try rawContents()
        guard var root = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let accountData = try JSONEncoder().encode(account)
        root[Self.accountKey] = try JSONSerialization.jsonObject(with: accountData)
        try current.write(to: backupURL, options: .atomic)
        try FileSystem.writePrivate(try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]), to: url)
    }

    public func rawContents() throws -> Data { try Data(contentsOf: url) }

    public func restore(_ data: Data) throws { try FileSystem.writePrivate(data, to: url) }

    var backupURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".switcher-bak") }
}
