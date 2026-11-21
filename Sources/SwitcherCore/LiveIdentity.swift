import Foundation

/// Who the live Claude Code login (the Keychain item) belongs to.
public struct LiveLogin: Equatable, Sendable {
    public let email: String
    public let orgId: String

    public init(email: String, orgId: String) { self.email = email; self.orgId = orgId }
}

public protocol LiveIdentity: Sendable {
    /// nil when signed out.
    func current() throws -> LiveLogin?
}

/// Asks Claude Code itself (`claude auth status --json`). Unlike `~/.claude.json`, which every running
/// Claude Code process rewrites from memory, this reflects the login actually in the Keychain.
public struct ClaudeAuthStatus: LiveIdentity {
    let runner: CommandRunner
    let claudePath: @Sendable () -> String?

    public init(runner: CommandRunner = ProcessRunner(), claudePath: @escaping @Sendable () -> String? = LoginLauncher.claudePath) {
        self.runner = runner; self.claudePath = claudePath
    }

    private struct Status: Decodable {
        var loggedIn: Bool?
        var email: String?
        var orgId: String?
    }

    public func current() throws -> LiveLogin? {
        guard let path = claudePath() else {
            throw SwitchError.stepFailed(step: "check sign-in", underlying: "Claude Code (`claude`) was not found")
        }
        let result = try runner.run(path, ["auth", "status", "--json"])
        guard let status = try? JSONDecoder().decode(Status.self, from: result.stdout) else {
            throw SwitchError.stepFailed(step: "check sign-in", underlying: "`claude auth status` gave no readable answer")
        }
        guard status.loggedIn == true, let email = status.email, let org = status.orgId else { return nil }
        return LiveLogin(email: email, orgId: org)
    }
}

/// The live login resolved against the saved accounts.
public enum LiveAccount: Equatable, Sendable {
    case signedOut
    /// A saved account.
    case known(String)
    /// Not saved yet; `~/.claude.json` agrees with the live login, so its account details are usable.
    case new(id: String, account: [String: JSONValue])
    /// Not saved yet, and `~/.claude.json` names someone else — wait for it to catch up.
    case unresolved(email: String)
}

public extension SwitcherEnvironment {
    /// Identifies the live login via `claude auth status`; `~/.claude.json` is only trusted when it agrees.
    func resolveLive(_ state: SwitcherState) throws -> LiveAccount {
        guard let login = try identity.current() else { return .signedOut }
        let sameEmail = { (e: String?) in e?.caseInsensitiveCompare(login.email) == .orderedSame }
        if let p = state.profiles.first(where: { sameEmail($0.email) && $0.orgUuid == login.orgId })
            ?? state.profiles.first(where: { sameEmail($0.email) }) {
            return .known(p.id)
        }
        if let account = try? claudeJSON.readAccount(), sameEmail(account["emailAddress"]?.stringValue),
           account["organizationUuid"]?.stringValue == login.orgId, let id = account["accountUuid"]?.stringValue {
            return state.profile(id) != nil ? .known(id) : .new(id: id, account: account)
        }
        return .unresolved(email: login.email)
    }

    /// The saved account the live login belongs to, if any.
    func liveKnownId(_ state: SwitcherState) throws -> String? {
        if case .known(let id) = try resolveLive(state) { return id }
        return nil
    }
}
