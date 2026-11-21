import Foundation

public enum WatchEvent: Equatable, Sendable {
    case none
    case added(Profile)
    case addedAndRestored(added: Profile, restored: String)
    /// The CLI is signed in to a saved account other than the one marked active.
    case activeChanged(String)
}

/// Notices new Claude Code sign-ins and saves them; drives the "Add account" flow.
public final class AccountWatcher: @unchecked Sendable {
    let env: SwitcherEnvironment
    private var returnTo: String?
    public private(set) var isAdding = false
    /// True while the background `claude auth login` is still running; nothing is captured until it exits.
    public var signInInProgress = false

    public init(env: SwitcherEnvironment) { self.env = env }

    private var switcher: Switcher { Switcher(env: env) }

    /// Call right before starting a sign-in. Saves the current login first, because the sign-in replaces it.
    public func beginAdd() throws {
        try switcher.saveLiveLoginBack()
        returnTo = try env.claudeJSON.readAccount()?["accountUuid"]?.stringValue
        isAdding = true
    }

    /// Cancels an add and, if the sign-in removed or replaced the previous login, puts the previous account back.
    public func abandonAdd() throws {
        let previous = returnTo
        cancelAdd()
        guard let previous, try env.store.load().profile(previous) != nil else { return }
        let liveId = (try? env.claudeJSON.readAccount())?["accountUuid"]?.stringValue
        let live = try env.secrets.read(service: ServiceNames.claudeCode)
        if live == nil || liveId != previous { try switcher.switchCLI(to: previous) }
    }

    public func cancelAdd() {
        isAdding = false
        returnTo = nil
    }

    public func check() async throws -> WatchEvent {
        if signInInProgress { return .none }
        guard let account = try? env.claudeJSON.readAccount(), let liveId = account["accountUuid"]?.stringValue,
              let live = try env.secrets.read(service: ServiceNames.claudeCode) else { return .none }
        var state = try env.store.load()
        if let ignored = state.ignoredAccountId, ignored != liveId {
            state.ignoredAccountId = nil
            try env.store.save(state)
        }
        // A half-written sign-in: ~/.claude.json names one account while the Keychain still holds another
        // saved account's token. Wait until both agree.
        for other in state.profiles where other.id != liveId {
            if try env.secrets.read(service: ServiceNames.vault(other.id))?.secret == live.secret { return .none }
        }
        if state.profile(liveId) != nil {
            if isAdding && liveId != returnTo { cancelAdd() }   // signed in to an account we already have
            if state.activeId != liveId {
                state.activeId = liveId
                try env.store.save(state)
                return .activeChanged(liveId)
            }
            return .none
        }
        if state.ignoredAccountId == liveId { return .none }

        let email = account["emailAddress"]?.stringValue ?? liveId
        let label = email.split(separator: "@").first.map(String.init) ?? email
        let added = try await switcher.captureCurrent(label: label, role: state.profiles.isEmpty ? .main : .backup,
                                                     includeDesktop: false)
        let wasAdding = isAdding, previous = returnTo
        cancelAdd()
        if wasAdding, let previous, previous != added.id, try env.store.load().profile(previous) != nil {
            try switcher.switchCLI(to: previous)
            return .addedAndRestored(added: added, restored: previous)
        }
        return .added(added)
    }
}
