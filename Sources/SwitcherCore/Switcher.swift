import Foundation

public struct SwitchResult: Equatable, Sendable {
    public var to: String
    public var sharedSessionIds: [String]
    public var warnings: [String]
}

public enum SwitchError: Error, Equatable {
    case unknownProfile(String)
    case alreadyActive
    case noLiveLogin
    case missingSecret(String)
    case stepFailed(step: String, underlying: String)
    /// The Keychain holds a token saved for another profile while ~/.claude.json names `active`.
    case loginMismatch(active: String, tokenOwner: String)
    /// Claude Code is signed in to an account that isn't saved yet.
    case unsavedLiveLogin(email: String)
    /// A step failed and putting things back also failed for the listed parts.
    case rollbackIncomplete(step: String, failures: [String])
}

public final class Switcher: @unchecked Sendable {
    let env: SwitcherEnvironment

    public init(env: SwitcherEnvironment) { self.env = env }

    /// Saves the currently signed-in Claude Code login (and optionally Claude Desktop's) as a profile.
    public func captureCurrent(label: String, role: ProfileRole, includeDesktop: Bool) async throws -> Profile {
        guard let live = try env.secrets.read(service: ServiceNames.claudeCode) else { throw SwitchError.noLiveLogin }
        let account: [String: JSONValue], id: String
        switch try env.resolveLive(try env.store.load()) {
        case .new(let newId, let newAccount): (id, account) = (newId, newAccount)
        case .known(let knownId):
            guard let saved = try env.store.load().profile(knownId) else { throw SwitchError.noLiveLogin }
            (id, account) = (knownId, saved.oauthAccount)
        case .signedOut, .unresolved: throw SwitchError.noLiveLogin
        }
        try repairOtherCopies(of: live.secret, owner: id)
        try saveVault(id, account: live.account, secret: live.secret)

        var state = try env.store.load()
        var hasDesktop = state.profile(id)?.hasDesktopSnapshot ?? false
        if includeDesktop {
            let wasRunning = env.desktop.isRunning
            if wasRunning { try await env.desktop.quit() }
            defer { if wasRunning { try? env.desktop.launch() } }
            try env.desktopLogin.capture(into: id)
            hasDesktop = true
        }
        let profile = Profile(id: id, label: label, role: role,
                              orgUuid: account["organizationUuid"]?.stringValue ?? "",
                              email: account["emailAddress"]?.stringValue ?? "",
                              oauthAccount: account, hasDesktopSnapshot: hasDesktop)
        state.profiles.removeAll { $0.id == id }
        state.profiles.append(profile)
        state.activeId = id
        try env.store.save(state)
        return profile
    }

    public func switchTo(_ targetId: String) async throws -> SwitchResult {
        let state = try env.store.load()
        guard let target = state.profile(targetId) else { throw SwitchError.unknownProfile(targetId) }
        let resolved = try env.resolveLive(state)
        let currentId: String?
        switch resolved {
        case .known(let id): currentId = id
        case .signedOut: currentId = nil      // e.g. after a cancelled sign-in: just put the target back
        case .new(_, let account):
            throw SwitchError.unsavedLiveLogin(email: account["emailAddress"]?.stringValue ?? "the current account")
        case .unresolved(let email): throw SwitchError.unsavedLiveLogin(email: email)
        }
        if currentId == targetId { throw SwitchError.alreadyActive }
        let liveAccount = currentId.flatMap { state.profile($0) }?.oauthAccount
        guard let targetSecret = try env.secrets.read(service: ServiceNames.vault(targetId)) else {
            throw SwitchError.missingSecret(target.label)
        }
        let live = try env.secrets.read(service: ServiceNames.claudeCode)
        var current = currentId.flatMap { state.profile($0) }

        // 0. The live login is verified to be the current account's, so any other account holding the same
        //    login has a wrong copy (from an earlier mix-up) — remove it rather than ever restoring it.
        if let live, let profile = current { try repairOtherCopies(of: live.secret, owner: profile.id) }

        // 1. The live login always wins: save it back into the current profile (keeping the old copy).
        if var profile = current {
            if let live { try saveVault(profile.id, account: live.account, secret: live.secret) }
            if let liveAccount { profile.oauthAccount = liveAccount }
            current = profile
        }

        // 2. Quit Desktop and save its live login back too; on failure reopen it and stop.
        let wasRunning = env.desktop.isRunning
        var desktopCapturedFor: String?
        do {
            if wasRunning { try await env.desktop.quit() }
            if let owner = desktopOwner(state), state.profile(owner) != nil {
                try env.desktopLogin.capture(into: owner)
                desktopCapturedFor = owner
            }
        } catch {
            if wasRunning && !env.desktop.isRunning { try? env.desktop.launch() }
            if let e = error as? SwitchError { throw e }
            throw SwitchError.stepFailed(step: "save Desktop login", underlying: String(describing: error))
        }

        // 3. Snapshot everything we are about to change.
        let jsonBefore = try env.claudeJSON.rawContents()
        let desktopBackup = try env.desktopLogin.backupCurrent()
        var keepBackup = false
        defer { if !keepBackup { try? FileManager.default.removeItem(at: desktopBackup) } }

        var step = "write Claude Code login"
        do {
            try env.secrets.write(service: ServiceNames.claudeCode, account: live?.account ?? targetSecret.account,
                                  secret: targetSecret.secret)
            step = "write account to ~/.claude.json"
            try env.claudeJSON.writeAccount(target.oauthAccount)

            var warnings: [String] = []
            var appliedDesktop = false
            step = "apply Desktop login"
            if env.desktopLogin.hasSnapshot(targetId) {
                try env.desktopLogin.apply(from: targetId)
                appliedDesktop = true
            } else {
                warnings.append("Sign in to Claude Desktop once as \(target.label); the app remembers it after that.")
            }

            step = "merge Desktop sessions"
            var shared: [String] = []
            if let profile = current, !profile.orgUuid.isEmpty, !target.orgUuid.isEmpty {
                shared = try env.sessions.merge((profile.id, profile.orgUuid), (target.id, target.orgUuid)).toB
            }

            step = "save switcher state"
            // Re-read so changes made while Desktop was quitting (stars, settings) are kept.
            var fresh = try env.store.load()
            if let profile = current, let i = fresh.profiles.firstIndex(where: { $0.id == profile.id }) {
                fresh.profiles[i].oauthAccount = profile.oauthAccount
            }
            if let owner = desktopCapturedFor, let i = fresh.profiles.firstIndex(where: { $0.id == owner }) {
                fresh.profiles[i].hasDesktopSnapshot = true
            }
            if appliedDesktop {
                fresh.desktopAccountId = targetId
                fresh.desktopAppliedAt = Date()
            }
            // Keep Claude Code's last usage numbers for the account we're leaving.
            if let profile = current, let cache = UsageParser.parseCache(jsonBefore, accountUuid: profile.id),
               cache.fetchedAt > (fresh.lastUsage[profile.id]?.fetchedAt ?? .distantPast) {
                fresh.lastUsage[profile.id] = cache
            }
            fresh.activeId = targetId
            try env.store.save(fresh)

            // The switch is complete; failing to reopen Desktop is only worth a warning.
            if wasRunning {
                do { try env.desktop.launch() } catch {
                    warnings.append("Couldn't reopen Claude Desktop — open it yourself.")
                }
            }
            return SwitchResult(to: targetId, sharedSessionIds: shared, warnings: warnings)
        } catch {
            var failures: [String] = []
            do {
                if let live {
                    try env.secrets.write(service: ServiceNames.claudeCode, account: live.account, secret: live.secret)
                } else {
                    try env.secrets.delete(service: ServiceNames.claudeCode)
                }
            } catch { failures.append("Claude Code login") }
            do { try env.claudeJSON.restore(jsonBefore) } catch { failures.append("~/.claude.json (backup at ~/.claude.json.switcher-bak)") }
            do { try env.desktopLogin.restore(from: desktopBackup) } catch {
                keepBackup = true
                failures.append("Desktop login (backup kept at \(desktopBackup.path))")
            }
            if wasRunning && !env.desktop.isRunning { try? env.desktop.launch() }
            if !failures.isEmpty { throw SwitchError.rollbackIncomplete(step: step, failures: failures) }
            throw SwitchError.stepFailed(step: step, underlying: String(describing: error))
        }
    }

    /// Points the Claude Code login (CLI and VS Code) at a saved account. Desktop and sessions are untouched.
    public func switchCLI(to id: String) throws {
        var state = try env.store.load()
        guard let profile = state.profile(id) else { throw SwitchError.unknownProfile(id) }
        guard let saved = try env.secrets.read(service: ServiceNames.vault(id)) else { throw SwitchError.missingSecret(profile.label) }
        let live = try env.secrets.read(service: ServiceNames.claudeCode)
        let jsonBefore = try env.claudeJSON.rawContents()
        do {
            try env.secrets.write(service: ServiceNames.claudeCode, account: live?.account ?? saved.account, secret: saved.secret)
            try env.claudeJSON.writeAccount(profile.oauthAccount)
        } catch {
            if let live { try? env.secrets.write(service: ServiceNames.claudeCode, account: live.account, secret: live.secret) }
            else { try? env.secrets.delete(service: ServiceNames.claudeCode) }
            try? env.claudeJSON.restore(jsonBefore)
            throw SwitchError.stepFailed(step: "switch Claude Code login", underlying: String(describing: error))
        }
        state.activeId = id
        try env.store.save(state)
    }

    /// Saves the live Claude Code login into the saved account it belongs to (per `claude auth status`).
    public func saveLiveLoginBack() throws {
        let state = try env.store.load()
        guard let id = try env.liveKnownId(state),
              let live = try env.secrets.read(service: ServiceNames.claudeCode) else { return }
        try repairOtherCopies(of: live.secret, owner: id)
        try saveVault(id, account: live.account, secret: live.secret)
    }

    /// Deletes copies of `secret` saved under accounts other than its verified owner.
    func repairOtherCopies(of secret: Data, owner: String) throws {
        for other in try env.store.load().profiles where other.id != owner {
            if try env.secrets.read(service: ServiceNames.vault(other.id))?.secret == secret {
                try env.secrets.delete(service: ServiceNames.vault(other.id))
            }
        }
    }

    /// Forgets a saved account: its saved logins (Claude Code and Desktop) are deleted.
    public func removeProfile(_ id: String) throws {
        guard !id.isEmpty else { throw SwitchError.unknownProfile(id) }
        var state = try env.store.load()
        try env.secrets.delete(service: ServiceNames.vault(id))
        try env.secrets.delete(service: ServiceNames.vaultPrevious(id))
        try env.desktopLogin.removeSnapshot(id)
        state.profiles.removeAll { $0.id == id }
        state.lastUsage[id] = nil
        if try env.claudeJSON.readAccount()?["accountUuid"]?.stringValue == id { state.ignoredAccountId = id }
        if state.activeId == id { state.activeId = nil }
        try env.store.save(state)
    }

    /// The account Claude Desktop is signed in to. Desktop's config names the old account until it runs
    /// again after we swap its files, so our own record wins while the config is older than our last apply.
    private func desktopOwner(_ state: SwitcherState) -> String? {
        let config = env.desktopAccount.signedInAccount()
        if let recorded = state.desktopAccountId, let appliedAt = state.desktopAppliedAt,
           config == nil || config!.modifiedAt <= appliedAt {
            return recorded
        }
        return config?.id
    }

    func saveVault(_ id: String, account: String, secret: Data) throws {
        if let existing = try env.secrets.read(service: ServiceNames.vault(id)), existing.secret != secret {
            try env.secrets.write(service: ServiceNames.vaultPrevious(id), account: existing.account, secret: existing.secret)
        }
        try env.secrets.write(service: ServiceNames.vault(id), account: account, secret: secret)
    }
}
