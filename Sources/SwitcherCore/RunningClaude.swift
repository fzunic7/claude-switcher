import Foundation

/// Counts running Claude Code processes: native `claude` binaries (including the ones Claude Desktop's
/// Code tab runs) and npm installs (`node …/@anthropic-ai/claude-code/…`).
public struct RunningClaude: Sendable {
    let runner: CommandRunner

    public init(runner: CommandRunner = ProcessRunner()) { self.runner = runner }

    public func cliProcessCount() throws -> Int {
        let result = try runner.run("/usr/bin/pgrep", ["-lf", "claude"])
        guard result.status == 0 else { return 0 }
        return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).filter { line in
            let command = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let executable = command.split(separator: " ").first.map(String.init) ?? ""
            return URL(fileURLWithPath: executable).lastPathComponent == "claude"
                || command.contains("@anthropic-ai/claude-code")
        }.count
    }
}
