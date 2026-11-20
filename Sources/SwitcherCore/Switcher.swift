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
        var state = try env.store.load()
        guard let target = state.profile(targetId) else { throw SwitchError.unknownProfile(targetId) }
        let liveAccount = try env.claudeJSON.readAccount()
        let currentId = liveAccount?["accountUuid"]?.stringValue ?? state.activeId
        if currentId == targetId { throw SwitchError.alreadyActive }
        guard let targetSecret = try env.secrets.read(service: ServiceNames.vault(targetId)) else {
            throw SwitchError.missingSecret(target.label)
        }

        // 1. The live login always wins: save it back into the current profile before touching anything.
        let live = try env.secrets.read(service: ServiceNames.claudeCode)
        var current = currentId.flatMap { state.profile($0) }
        if var profile = current {
            if let live { try env.secrets.write(service: ServiceNames.vault(profile.id), account: live.account, secret: live.secret) }
            if let liveAccount { profile.oauthAccount = liveAccount }
            current = profile
        }

        // 2. Quit Desktop and save its live login back too.
        let wasRunning = env.desktop.isRunning
        if wasRunning { try await env.desktop.quit() }
        if let profile = current, profile.hasDesktopSnapshot {
            try env.desktopLogin.capture(into: profile.id)
        }

        // 3. Snapshot everything we are about to change.
        let jsonBefore = try env.claudeJSON.rawContents()
        let desktopBackup = try env.desktopLogin.backupCurrent()
        defer { try? FileManager.default.removeItem(at: desktopBackup) }

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
            if let profile = current {
                let from = (profile.id, profile.orgUuid), to = (target.id, target.orgUuid)
                let ids = state.shareAll
                    ? Set(try env.sessions.list(account: from.0, org: from.1).map(\.id))
                    : state.sharedSessionIds
                shared = try env.sessions.share(ids: ids, from: from, to: to)
            }

            step = "save switcher state"
            if let profile = current, let i = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                state.profiles[i] = profile
            }
            state.activeId = targetId
            try env.store.save(state)

            if wasRunning { try env.desktop.launch() }
            return SwitchResult(to: targetId, sharedSessionIds: shared, warnings: warnings)
        } catch {
            if let live { try? env.secrets.write(service: ServiceNames.claudeCode, account: live.account, secret: live.secret) }
            try? env.claudeJSON.restore(jsonBefore)
            try? env.desktopLogin.restore(from: desktopBackup)
            if wasRunning { try? env.desktop.launch() }
            throw SwitchError.stepFailed(step: step, underlying: String(describing: error))
        }
    }
}
