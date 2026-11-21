import Foundation

public enum WatchEvent: Equatable, Sendable {
    case none
    case added(Profile)
    case addedAndRestored(added: Profile, restored: String)
}

/// Notices new Claude Code sign-ins and saves them; drives the "Add account" flow.
public final class AccountWatcher: @unchecked Sendable {
    let env: SwitcherEnvironment
    private var returnTo: String?
    public private(set) var isAdding = false

    public init(env: SwitcherEnvironment) { self.env = env }

    private var switcher: Switcher { Switcher(env: env) }

    /// Call right before starting a sign-in. Saves the current login first, because the sign-in replaces it.
    public func beginAdd() throws {
        try switcher.saveLiveLoginBack()
        returnTo = try env.claudeJSON.readAccount()?["accountUuid"]?.stringValue
        isAdding = true
    }

    public func cancelAdd() {
        isAdding = false
        returnTo = nil
    }

    public func check() async throws -> WatchEvent {
        guard let account = try? env.claudeJSON.readAccount(), let liveId = account["accountUuid"]?.stringValue,
              try env.secrets.read(service: ServiceNames.claudeCode) != nil else { return .none }
        var state = try env.store.load()
        if let ignored = state.ignoredAccountId, ignored != liveId {
            state.ignoredAccountId = nil
            try env.store.save(state)
        }
        if state.profile(liveId) != nil || state.ignoredAccountId == liveId {
            if isAdding && liveId != returnTo { cancelAdd() }   // signed in to an account we already have
            return .none
        }

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
