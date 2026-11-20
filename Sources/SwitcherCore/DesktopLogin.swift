import Foundation

public protocol DesktopLoginStore: Sendable {
    func capture(into accountUuid: String) throws
    func hasSnapshot(_ accountUuid: String) -> Bool
    func apply(from accountUuid: String) throws
    func backupCurrent() throws -> URL
    func restore(from backup: URL) throws
}

/// Copies the Claude Desktop files that hold its sign-in in and out of a per-account vault folder.
public struct DesktopLoginFiles: DesktopLoginStore {
    /// Provisional until the hand-run spike (plan Task 0) confirms the minimal set.
    public static let defaultPaths = [
        "Cookies", "Cookies-journal", "Local Storage", "Session Storage", "IndexedDB", "WebStorage", "Partitions",
    ]

    public let supportRoot: URL
    public let vaultRoot: URL
    public let paths: [String]

    public init(supportRoot: URL, vaultRoot: URL, paths: [String] = Self.defaultPaths) {
        self.supportRoot = supportRoot; self.vaultRoot = vaultRoot; self.paths = paths
    }

    func snapshotDir(_ accountUuid: String) -> URL {
        vaultRoot.appendingPathComponent(accountUuid).appendingPathComponent("desktop")
    }

    public func capture(into accountUuid: String) throws {
        try FileSystem.ensurePrivateDirectory(vaultRoot)
        try FileSystem.ensurePrivateDirectory(vaultRoot.appendingPathComponent(accountUuid))
        try copyListed(from: supportRoot, to: snapshotDir(accountUuid))
    }

    public func hasSnapshot(_ accountUuid: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotDir(accountUuid).path)
    }

    public func apply(from accountUuid: String) throws {
        try replaceListed(in: supportRoot, with: snapshotDir(accountUuid))
    }

    public func backupCurrent() throws -> URL {
        try FileSystem.ensurePrivateDirectory(vaultRoot)
        let backup = vaultRoot.appendingPathComponent("backup-\(UUID().uuidString)")
        try copyListed(from: supportRoot, to: backup)
        return backup
    }

    public func restore(from backup: URL) throws {
        try replaceListed(in: supportRoot, with: backup)
    }

    /// Replaces `dest` with a fresh copy of the listed paths in `source` (missing ones skipped).
    private func copyListed(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try FileSystem.ensurePrivateDirectory(dest)
        for path in paths {
            let src = source.appendingPathComponent(path)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: dest.appendingPathComponent(path))
        }
    }

    /// Makes each listed path in `target` match `snapshot`, removing it when the snapshot lacks it.
    private func replaceListed(in target: URL, with snapshot: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.path) else { throw CocoaError(.fileNoSuchFile) }
        for path in paths {
            let dst = target.appendingPathComponent(path)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            let src = snapshot.appendingPathComponent(path)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
        }
    }
}
