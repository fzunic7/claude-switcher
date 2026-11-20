import Foundation

public final class ProfileStore: @unchecked Sendable {
    public let root: URL
    private var fileURL: URL { root.appendingPathComponent("profiles.json") }

    public init(root: URL) { self.root = root }

    public func load() throws -> SwitcherState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SwitcherState() }
        return try JSONDecoder().decode(SwitcherState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: SwitcherState) throws {
        try FileSystem.ensurePrivateDirectory(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileSystem.writePrivate(try encoder.encode(state), to: fileURL)
    }
}
