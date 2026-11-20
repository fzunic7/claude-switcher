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

public struct SwitcherState: Codable, Equatable, Sendable {
    public var profiles: [Profile]
    public var activeId: String?
    public var sharedSessionIds: Set<String>
    public var shareAll: Bool

    public init(profiles: [Profile] = [], activeId: String? = nil, sharedSessionIds: Set<String> = [], shareAll: Bool = false) {
        self.profiles = profiles; self.activeId = activeId
        self.sharedSessionIds = sharedSessionIds; self.shareAll = shareAll
    }

    public func profile(_ id: String) -> Profile? { profiles.first { $0.id == id } }
}
