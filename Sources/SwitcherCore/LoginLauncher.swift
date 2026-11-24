import Foundation

/// Starts Claude Code's own sign-in (`claude auth login`), which opens the Claude website in the browser.
public enum LoginLauncher {
    public static func claudePath() -> String? {
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        guard let result = try? ProcessRunner().run("/bin/zsh", ["-lc", "command -v claude"]), result.status == 0 else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Runs the sign-in in the background; output goes to `login.log` in the app's support folder.
    public static func startLogin(environment: [String: String] = [:]) throws -> Process {
        guard let claude = claudePath() else {
            throw SwitchError.stepFailed(step: "start sign-in", underlying: "Claude Code (`claude`) was not found")
        }
        let logURL = SwitcherEnvironment.switcherRoot.appendingPathComponent("login.log")
        try FileSystem.ensurePrivateDirectory(SwitcherEnvironment.switcherRoot)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login"]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in try? log.close() }
        try process.run()
        return process
    }

    /// Fallback when the background sign-in can't finish on its own: run it in Terminal.
    public static func openInTerminal(configDir: String? = nil) throws {
        let path = claudePath() ?? "claude"
        let script = configDir.map { terminalScript(claudePath: path, configDir: $0) } ?? terminalScript(claudePath: path)
        let result = try ProcessRunner().run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            throw SwitchError.stepFailed(step: "open Terminal", underlying: "osascript exited with \(result.status)")
        }
    }

    static func terminalScript(claudePath: String) -> String {
        let shellQuoted = "'" + claudePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = (shellQuoted + " auth login")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\" to do script \"\(command)\"\ntell application \"Terminal\" to activate"
    }

    static func terminalScript(claudePath: String, configDir: String) -> String {
        script(for: "CLAUDE_CONFIG_DIR=\(shellQuote(configDir)) \(shellQuote(claudePath)) auth login")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func script(for shellCommand: String) -> String {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
    }
}
