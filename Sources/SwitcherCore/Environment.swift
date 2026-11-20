import Foundation

public protocol DesktopAppControl: Sendable {
    var isRunning: Bool { get }
    func quit() async throws
    func launch() throws
}

public struct SwitcherEnvironment: Sendable {
    public var store: ProfileStore
    public var secrets: SecretStore
    public var claudeJSON: ClaudeJSON
    public var desktopLogin: DesktopLoginStore
    public var sessions: SessionSharing
    public var desktop: DesktopAppControl

    public init(store: ProfileStore, secrets: SecretStore, claudeJSON: ClaudeJSON, desktopLogin: DesktopLoginStore,
                sessions: SessionSharing, desktop: DesktopAppControl) {
        self.store = store; self.secrets = secrets; self.claudeJSON = claudeJSON
        self.desktopLogin = desktopLogin; self.sessions = sessions; self.desktop = desktop
    }
}

public extension SwitcherEnvironment {
    static var switcherRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClaudeSwitcher")
    }
    static var desktopSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
    }

    static func live(desktop: DesktopAppControl) -> SwitcherEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SwitcherEnvironment(
            store: ProfileStore(root: switcherRoot),
            secrets: SecurityCLIStore(),
            claudeJSON: ClaudeJSON(url: home.appendingPathComponent(".claude.json")),
            desktopLogin: DesktopLoginFiles(supportRoot: desktopSupportRoot, vaultRoot: switcherRoot.appendingPathComponent("vault")),
            sessions: SessionIndex(sessionsRoot: desktopSupportRoot.appendingPathComponent("claude-code-sessions")),
            desktop: desktop)
    }
}
