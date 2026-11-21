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
        // An explicit add overrides "removed while signed in".
        var state = try env.store.load()
        if state.ignoredAccountId != nil {
            state.ignoredAccountId = nil
            try env.store.save(state)
        }
        returnTo = try env.liveKnownId(state)
        isAdding = true
    }

    /// Cancels an add and, if the sign-in removed or replaced the previous login, puts the previous account back.
    public func abandonAdd() throws {
        let previous = returnTo
        cancelAdd()
        let state = try env.store.load()
        guard let previous, state.profile(previous) != nil else { return }
        let liveId = try? env.liveKnownId(state)
        if liveId != previous { try switcher.switchCLI(to: previous) }
    }

    public func cancelAdd() {
        isAdding = false
        returnTo = nil
    }

    public func check() async throws -> WatchEvent {
        if signInInProgress { return .none }
        guard let live = try env.secrets.read(service: ServiceNames.claudeCode) else { return .none }
        var state = try env.store.load()
        // No answer from `claude auth status` means we don't know whose login it is: do nothing.
        guard let resolved = try? env.resolveLive(state) else { return .none }

        let liveId: String
        switch resolved {
        case .signedOut, .unresolved: return .none
        case .known(let id): liveId = id
        case .new(let id, _): liveId = id
        }
        if let ignored = state.ignoredAccountId, ignored != liveId {
            state.ignoredAccountId = nil
            try env.store.save(state)
        }

        if case .known(let id) = resolved {
            try switcher.repairOtherCopies(of: live.secret, owner: id)
            try switcher.saveVault(id, account: live.account, secret: live.secret)   // keep its saved copy fresh
            if isAdding && id != returnTo { cancelAdd() }   // signed in to an account we already have
            state = try env.store.load()
            if state.activeId != id {
                state.activeId = id
                try env.store.save(state)
                return .activeChanged(id)
            }
            return .none
        }
        if state.ignoredAccountId == liveId { return .none }
        guard case .new(_, let account) = resolved else { return .none }

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
