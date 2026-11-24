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
    /// Where records removed because they were deleted elsewhere are moved (kept, not erased). nil: erase.
    public let trashRoot: URL?

    public init(sessionsRoot: URL, trashRoot: URL? = nil) { self.sessionsRoot = sessionsRoot; self.trashRoot = trashRoot }

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
            guard Self.isSessionId(id), !isDeleted(id, in: dir),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let r = try? JSONDecoder().decode(Record.self, from: data),
                  r.isArchived != true else { return nil }
            return DesktopSession(id: id, title: r.title ?? "Untitled", cwd: r.cwd ?? "",
                                  lastActivityAt: Date(timeIntervalSince1970: (r.lastActivityAt ?? 0) / 1000),
                                  isArchived: false)
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func lastActivity(_ url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.lastActivityAt
    }

    /// Copies the selected records into the target account's folder. An existing record is replaced only by a
    /// newer one (higher `lastActivityAt`); unreadable or newer records are never touched. Returns ids written.
    public func share(ids: Set<String>, from: (String, String), to: (String, String)) throws -> [String] {
        let fm = FileManager.default
        let src = folder(from.0, from.1), dst = folder(to.0, to.1)
        var copied: [String] = []
        for id in ids.sorted() where Self.isSessionId(id) {
            let source = src.appendingPathComponent("\(id).json")
            let target = dst.appendingPathComponent("\(id).json")
            // Deleted on either side: don't bring it back.
            guard fm.fileExists(atPath: source.path), !isDeleted(id, in: dst), !isDeleted(id, in: src) else { continue }
            if fm.fileExists(atPath: target.path) {
                // Refresh an older copy (newer title/activity), never a newer or unreadable one.
                guard let s = lastActivity(source), let t = lastActivity(target), s > t else { continue }
                let temp = dst.appendingPathComponent(".\(id).json.tmp")
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: source, to: temp)
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
            copied.append(id)
        }
        return copied
    }

    /// Makes both accounts' session lists match: deletions carry over, then every remaining session is
    /// copied to the side that lacks it (a newer copy replaces an older one).
    public func merge(_ a: (String, String), _ b: (String, String)) throws -> (toA: [String], toB: [String]) {
        let dirA = folder(a.0, a.1), dirB = folder(b.0, b.1)
        try removeDeletedRecords(in: dirA)
        try removeDeletedRecords(in: dirB)
        try carryDeletions(from: dirA, to: dirB)
        try carryDeletions(from: dirB, to: dirA)
        let toB = try share(ids: allIds(a), from: a, to: b)
        let toA = try share(ids: allIds(b), from: b, to: a)
        return (toA, toB)
    }

    // MARK: Deletions
    // Claude Desktop deletes a session by removing `local_<uuid>.json` and writing a marker file `deleted_<uuid>`.

    static func uuid(_ id: String) -> String { String(id.dropFirst("local_".count)) }

    func isDeleted(_ id: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("deleted_\(Self.uuid(id))").path)
    }

    func markers(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("deleted_") && !$0.hasSuffix(".json") }
            .map { String($0.dropFirst("deleted_".count)) }
            .filter { Self.isSessionId("local_" + $0) }
    }

    /// Records sitting next to their own deletion marker (brought back by an older version) go to the trash.
    func removeDeletedRecords(in dir: URL) throws {
        for uuid in markers(in: dir) {
            let record = dir.appendingPathComponent("local_\(uuid).json")
            if FileManager.default.fileExists(atPath: record.path) { try trash(record) }
        }
    }

    /// A session deleted on one side is deleted on the other too (record to the trash, marker copied).
    func carryDeletions(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dst.path) else { return }
        for uuid in markers(in: src) {
            let record = dst.appendingPathComponent("local_\(uuid).json")
            let marker = dst.appendingPathComponent("deleted_\(uuid)")
            guard fm.fileExists(atPath: record.path) else { continue }
            try trash(record)
            if !fm.fileExists(atPath: marker.path) {
                try fm.copyItem(at: src.appendingPathComponent("deleted_\(uuid)"), to: marker)
            }
        }
    }

    private func trash(_ url: URL) throws {
        let fm = FileManager.default
        guard let trashRoot else { try fm.removeItem(at: url); return }
        try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970))-\(url.deletingLastPathComponent().lastPathComponent)-\(url.lastPathComponent)"
        try fm.moveItem(at: url, to: trashRoot.appendingPathComponent(name))
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
