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
    /// A step failed and putting things back also failed for the listed parts.
    case rollbackIncomplete(step: String, failures: [String])
}

public final class Switcher: @unchecked Sendable {
    let env: SwitcherEnvironment

    public init(env: SwitcherEnvironment) { self.env = env }

    /// Saves the currently signed-in Claude Code login (and optionally Claude Desktop's) as a profile.
    public func captureCurrent(label: String, role: ProfileRole, includeDesktop: Bool) async throws -> Profile {
        guard let live = try env.secrets.read(service: ServiceNames.claudeCode),
              let account = try env.claudeJSON.readAccount(),
              let id = account["accountUuid"]?.stringValue else { throw SwitchError.noLiveLogin }
        try env.secrets.write(service: ServiceNames.vault(id), account: live.account, secret: live.secret)

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
        let liveAccount = try env.claudeJSON.readAccount()
        let currentId = liveAccount?["accountUuid"]?.stringValue ?? state.activeId
        if currentId == targetId { throw SwitchError.alreadyActive }
        guard let targetSecret = try env.secrets.read(service: ServiceNames.vault(targetId)) else {
            throw SwitchError.missingSecret(target.label)
        }
        let live = try env.secrets.read(service: ServiceNames.claudeCode)
        var current = currentId.flatMap { state.profile($0) }

        // 0. Refuse if the live token is one we saved for a different profile: ~/.claude.json and the
        //    Keychain disagree (e.g. a still-running claude wrote its old account back).
        if let live, let profile = current {
            for other in state.profiles where other.id != profile.id {
                if try env.secrets.read(service: ServiceNames.vault(other.id))?.secret == live.secret {
                    throw SwitchError.loginMismatch(active: profile.label, tokenOwner: other.label)
                }
            }
        }

        // 1. The live login always wins: save it back into the current profile (keeping the old copy).
        if var profile = current {
            if let live { try saveVault(profile.id, account: live.account, secret: live.secret) }
            if let liveAccount { profile.oauthAccount = liveAccount }
            current = profile
        }

        // 2. Quit Desktop and save its live login back too; on failure reopen it and stop.
        let wasRunning = env.desktop.isRunning
        do {
            if wasRunning { try await env.desktop.quit() }
            if let profile = current, profile.hasDesktopSnapshot { try env.desktopLogin.capture(into: profile.id) }
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
            step = "apply Desktop login"
            if target.hasDesktopSnapshot && env.desktopLogin.hasSnapshot(targetId) {
                try env.desktopLogin.apply(from: targetId)
            } else {
                warnings.append("No Desktop login saved for \(target.label); Desktop left unchanged.")
            }

            step = "share sessions"
            var shared: [String] = []
            if let profile = current, !profile.orgUuid.isEmpty, !target.orgUuid.isEmpty {
                let from = (profile.id, profile.orgUuid), to = (target.id, target.orgUuid)
                let ids = state.shareAll
                    ? Set(try env.sessions.list(account: from.0, org: from.1).map(\.id))
                    : state.sharedSessionIds
                shared = try env.sessions.share(ids: ids, from: from, to: to)
            }

            step = "save switcher state"
            // Re-read so changes made while Desktop was quitting (stars, settings) are kept.
            var fresh = try env.store.load()
            if let profile = current, let i = fresh.profiles.firstIndex(where: { $0.id == profile.id }) {
                fresh.profiles[i].oauthAccount = profile.oauthAccount
            }
            fresh.activeId = targetId
            try env.store.save(fresh)

            if wasRunning { try env.desktop.launch() }
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

    private func saveVault(_ id: String, account: String, secret: Data) throws {
        if let existing = try env.secrets.read(service: ServiceNames.vault(id)), existing.secret != secret {
            try env.secrets.write(service: ServiceNames.vaultPrevious(id), account: existing.account, secret: existing.secret)
        }
        try env.secrets.write(service: ServiceNames.vault(id), account: account, secret: secret)
    }
}
