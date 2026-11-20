import AppKit

/// The real Claude Desktop app.
public struct LiveDesktopApp: DesktopAppControl {
    public static let bundleId = "com.anthropic.claudefordesktop"

    public init() {}

    private var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId)
    }

    public var isRunning: Bool { !running.isEmpty }

    public func quit() async throws {
        running.forEach { $0.terminate() }
        for _ in 0..<50 {
            if !isRunning { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SwitchError.stepFailed(step: "quit Desktop", underlying: "Claude Desktop did not quit within 10 seconds")
    }

    public func launch() throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) else {
            throw SwitchError.stepFailed(step: "launch Desktop", underlying: "Claude Desktop is not installed")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
