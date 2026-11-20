import Foundation

/// Counts running `claude` CLI processes (includes ones Claude Desktop's Code tab spawned).
public struct RunningClaude: Sendable {
    let runner: CommandRunner

    public init(runner: CommandRunner = ProcessRunner()) { self.runner = runner }

    public func cliProcessCount() throws -> Int {
        let result = try runner.run("/usr/bin/pgrep", ["-x", "claude"])
        guard result.status == 0 else { return 0 }
        return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).count
    }
}
