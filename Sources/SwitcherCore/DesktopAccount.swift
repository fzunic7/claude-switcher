import Foundation

public protocol DesktopAccountReading: Sendable {
    /// The account Claude Desktop says it is signed in to, and when its config file last changed.
    func signedInAccount() -> (id: String, modifiedAt: Date)?
}

/// Reads `lastKnownAccountUuid` from Claude Desktop's `config.json`.
public struct DesktopConfigReader: DesktopAccountReading {
    public let configURL: URL

    public init(configURL: URL) { self.configURL = configURL }

    private struct Config: Decodable { var lastKnownAccountUuid: String? }

    public func signedInAccount() -> (id: String, modifiedAt: Date)? {
        guard let data = try? Data(contentsOf: configURL),
              let id = (try? JSONDecoder().decode(Config.self, from: data))?.lastKnownAccountUuid,
              let modified = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
        else { return nil }
        return (id, modified)
    }
}
