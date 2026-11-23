import Foundation

/// Decides, per account, between a live usage fetch and the best last-known numbers.
public final class UsageService: @unchecked Sendable {
    let secrets: SecretStore
    let claudeJSON: ClaudeJSON
    let store: ProfileStore
    let client: UsageClient
    let renewer: TokenRenewer
    let now: @Sendable () -> Date
    /// Accounts the usage service told to slow down ("too many requests"), and until when.
    private var blockedUntil: [String: Date] = [:]
    public static let backoff: TimeInterval = 15 * 60

    public init(secrets: SecretStore, claudeJSON: ClaudeJSON, store: ProfileStore, client: UsageClient = UsageClient(),
                renewer: TokenRenewer? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets; self.claudeJSON = claudeJSON; self.store = store; self.client = client
        self.renewer = renewer ?? TokenRenewer(http: client.http)
        self.now = now
    }

    public func refresh() async -> [String: AccountUsage] {
        guard let state = try? store.load() else { return [:] }
        // The active account as verified by the watcher (`claude auth status`), not ~/.claude.json.
        let liveId = state.activeId
        var result: [String: AccountUsage] = [:]
        var fresh: [String: AccountUsage] = [:]

        for profile in state.profiles {
            let isActive = profile.id == liveId
            let service = isActive ? ServiceNames.claudeCode : ServiceNames.vault(profile.id)
            let blocked = (blockedUntil[profile.id] ?? .distantPast) > now()
            if !blocked, let login = await renewedLogin(service: service, accountId: profile.id, isActive: isActive),
               let creds = OAuthCredentials.parse(login), isActive || creds.isValid(at: now()) {
                do {
                    let usage = try await client.fetch(accessToken: creds.accessToken)
                    result[profile.id] = usage
                    fresh[profile.id] = usage
                    continue
                } catch UsageError.http(429) {
                    blockedUntil[profile.id] = now().addingTimeInterval(Self.backoff)
                } catch {}
            }
            var candidates = [state.lastUsage[profile.id]]
            if isActive, let data = try? claudeJSON.rawContents() {
                candidates.append(UsageParser.parseCache(data, accountUuid: profile.id))
            }
            if var best = candidates.compactMap({ $0 }).max(by: { $0.fetchedAt < $1.fetchedAt }) {
                best.isLive = false
                result[profile.id] = best
            }
        }

        if !fresh.isEmpty, var latest = try? store.load() {
            // (fresh numbers are persisted below)
            fresh.forEach { latest.lastUsage[$0.key] = $0.value }
            try? store.save(latest)
        }
        return result
    }

    /// The account's login, renewed first if it has expired. A renewed login is written back where it came from
    /// (Claude Code's own item for the active account, so Claude Code uses it too) unless someone else — Claude
    /// Code itself — renewed it meanwhile, in which case theirs is used.
    private func renewedLogin(service: String, accountId: String, isActive: Bool) async -> Data? {
        guard let item = try? secrets.read(service: service) else { return nil }
        guard let renewed = try? await renewer.renewIfNeeded(item.secret, now: now()) else { return item.secret }
        let current = try? secrets.read(service: service)
        guard current?.secret == item.secret else { return current?.secret ?? item.secret }
        do {
            try secrets.write(service: service, account: item.account, secret: renewed)
            if isActive { try secrets.write(service: ServiceNames.vault(accountId), account: item.account, secret: renewed) }
        } catch {
            return item.secret
        }
        return renewed
    }
}
