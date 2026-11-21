import Foundation

/// Decides, per account, between a live usage fetch and the best last-known numbers.
public final class UsageService: @unchecked Sendable {
    let secrets: SecretStore
    let claudeJSON: ClaudeJSON
    let store: ProfileStore
    let client: UsageClient
    let now: @Sendable () -> Date

    public init(secrets: SecretStore, claudeJSON: ClaudeJSON, store: ProfileStore, client: UsageClient = UsageClient(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets; self.claudeJSON = claudeJSON; self.store = store; self.client = client; self.now = now
    }

    public func refresh() async -> [String: AccountUsage] {
        guard let state = try? store.load() else { return [:] }
        let liveId = (try? claudeJSON.readAccount())?["accountUuid"]?.stringValue
        var result: [String: AccountUsage] = [:]
        var fresh: [String: AccountUsage] = [:]

        for profile in state.profiles {
            let isActive = profile.id == liveId
            let service = isActive ? ServiceNames.claudeCode : ServiceNames.vault(profile.id)
            let creds = (try? secrets.read(service: service)).flatMap { OAuthCredentials.parse($0.secret) }
            // The live login is tried even when it looks expired: Claude Code may have refreshed it in memory.
            if let creds, isActive || creds.isValid(at: now()),
               let usage = try? await client.fetch(accessToken: creds.accessToken) {
                result[profile.id] = usage
                fresh[profile.id] = usage
                continue
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
            fresh.forEach { latest.lastUsage[$0.key] = $0.value }
            try? store.save(latest)
        }
        return result
    }
}
