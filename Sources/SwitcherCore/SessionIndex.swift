import Foundation

public struct DesktopSession: Identifiable, Equatable, Sendable {
    /// File name stem, e.g. `local_<uuid>`.
    public let id: String
    public let title: String
    public let cwd: String
    public let lastActivityAt: Date
    public let isArchived: Bool
}

public protocol SessionSharing: Sendable {
    func list(account: String, org: String) throws -> [DesktopSession]
    func share(ids: Set<String>, from: (String, String), to: (String, String)) throws -> [String]
    func merge(_ a: (String, String), _ b: (String, String)) throws -> (toA: [String], toB: [String])
}

/// Claude Desktop's per-account Code session list: `<root>/<accountUuid>/<orgUuid>/local_<id>.json`.
public struct SessionIndex: SessionSharing {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL) { self.sessionsRoot = sessionsRoot }

    private struct Record: Decodable {
        var title: String?
        var cwd: String?
        var lastActivityAt: Double?
        var isArchived: Bool?
    }

    func folder(_ account: String, _ org: String) -> URL {
        sessionsRoot.appendingPathComponent(account).appendingPathComponent(org)
    }

    static func isSessionId(_ id: String) -> Bool {
        id.hasPrefix("local_") && id.dropFirst(6).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && id.count > 6
    }

    public func list(account: String, org: String) throws -> [DesktopSession] {
        let dir = folder(account, org)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return names.compactMap { name -> DesktopSession? in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard Self.isSessionId(id),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let r = try? JSONDecoder().decode(Record.self, from: data),
                  r.isArchived != true else { return nil }
            return DesktopSession(id: id, title: r.title ?? "Untitled", cwd: r.cwd ?? "",
                                  lastActivityAt: Date(timeIntervalSince1970: (r.lastActivityAt ?? 0) / 1000),
                                  isArchived: false)
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Copies the selected records into the target account's folder; never overwrites. Returns copied ids.
    public func share(ids: Set<String>, from: (String, String), to: (String, String)) throws -> [String] {
        let fm = FileManager.default
        let src = folder(from.0, from.1), dst = folder(to.0, to.1)
        var copied: [String] = []
        for id in ids.sorted() where Self.isSessionId(id) {
            let source = src.appendingPathComponent("\(id).json")
            let target = dst.appendingPathComponent("\(id).json")
            let tombstone = dst.appendingPathComponent("deleted_\(id).json")   // deleted there: don't bring it back
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path),
                  !fm.fileExists(atPath: tombstone.path) else { continue }
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            copied.append(id)
        }
        return copied
    }

    /// Makes both accounts' session lists contain every session either has. Never overwrites.
    public func merge(_ a: (String, String), _ b: (String, String)) throws -> (toA: [String], toB: [String]) {
        let toB = try share(ids: allIds(a), from: a, to: b)
        let toA = try share(ids: allIds(b), from: b, to: a)
        return (toA, toB)
    }

    /// Every session record id in a folder, archived ones included.
    func allIds(_ folder: (String, String)) throws -> Set<String> {
        let dir = self.folder(folder.0, folder.1)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            return Self.isSessionId(id) ? id : nil
        })
    }
}
