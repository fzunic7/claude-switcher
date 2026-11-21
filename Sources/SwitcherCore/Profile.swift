import Foundation

public enum ProfileRole: String, Codable, Sendable { case main, backup }

public struct Profile: Codable, Equatable, Identifiable, Sendable {
    /// The Claude accountUuid.
    public var id: String
    public var label: String
    public var role: ProfileRole
    public var orgUuid: String
    public var email: String
    public var oauthAccount: [String: JSONValue]
    public var hasDesktopSnapshot: Bool

    public init(id: String, label: String, role: ProfileRole, orgUuid: String, email: String,
                oauthAccount: [String: JSONValue], hasDesktopSnapshot: Bool) {
        self.id = id; self.label = label; self.role = role; self.orgUuid = orgUuid
        self.email = email; self.oauthAccount = oauthAccount; self.hasDesktopSnapshot = hasDesktopSnapshot
    }
}

public extension Profile {
    /// Plan badge derived from `oauthAccount.organizationType`.
    var plan: String? {
        switch oauthAccount["organizationType"]?.stringValue {
        case "claude_max": "Max"
        case "claude_pro": "Pro"
        case "claude_team": "Team"
        case "claude_enterprise": "Enterprise"
        default: nil
        }
    }
}

public struct SwitcherState: Codable, Equatable, Sendable {
    public var profiles: [Profile]
    public var activeId: String?
    /// Unused since v0.2 (sessions are merged both ways); kept so older files round-trip.
    public var sharedSessionIds: Set<String>
    public var shareAll: Bool
    /// A removed account that is still the live CLI login; not re-added until the CLI moves off it.
    public var ignoredAccountId: String?
    /// The account whose Desktop login the switcher last applied, and when.
    public var desktopAccountId: String?
    public var desktopAppliedAt: Date?
    /// Last known usage per account id.
    public var lastUsage: [String: AccountUsage]

    public init(profiles: [Profile] = [], activeId: String? = nil, sharedSessionIds: Set<String> = [], shareAll: Bool = false,
                ignoredAccountId: String? = nil, desktopAccountId: String? = nil, desktopAppliedAt: Date? = nil,
                lastUsage: [String: AccountUsage] = [:]) {
        self.profiles = profiles; self.activeId = activeId
        self.sharedSessionIds = sharedSessionIds; self.shareAll = shareAll
        self.ignoredAccountId = ignoredAccountId; self.desktopAccountId = desktopAccountId
        self.desktopAppliedAt = desktopAppliedAt; self.lastUsage = lastUsage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        activeId = try c.decodeIfPresent(String.self, forKey: .activeId)
        sharedSessionIds = try c.decodeIfPresent(Set<String>.self, forKey: .sharedSessionIds) ?? []
        shareAll = try c.decodeIfPresent(Bool.self, forKey: .shareAll) ?? false
        ignoredAccountId = try c.decodeIfPresent(String.self, forKey: .ignoredAccountId)
        desktopAccountId = try c.decodeIfPresent(String.self, forKey: .desktopAccountId)
        desktopAppliedAt = try c.decodeIfPresent(Date.self, forKey: .desktopAppliedAt)
        lastUsage = try c.decodeIfPresent([String: AccountUsage].self, forKey: .lastUsage) ?? [:]
    }

    public func profile(_ id: String) -> Profile? { profiles.first { $0.id == id } }
}
