import Foundation

/// One rate-limit window (the 5-hour session or the weekly limit).
public struct UsageWindow: Codable, Equatable, Sendable {
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization; self.resetsAt = resetsAt
    }
}

/// Spending beyond the plan ("Extra usage"). Amounts are in minor units (see `decimalPlaces`).
public struct ExtraUsage: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var utilization: Double?
    public var currency: String?
    public var decimalPlaces: Int
    public var spendLimitReached: Bool

    public init(isEnabled: Bool, monthlyLimit: Double?, usedCredits: Double?, utilization: Double?,
                currency: String?, decimalPlaces: Int, spendLimitReached: Bool) {
        self.isEnabled = isEnabled; self.monthlyLimit = monthlyLimit; self.usedCredits = usedCredits
        self.utilization = utilization; self.currency = currency; self.decimalPlaces = decimalPlaces
        self.spendLimitReached = spendLimitReached
    }
}

/// One limit that applies to the account, as listed by the usage service (plans differ: Max has no
/// 5-hour session limit but can have per-model weekly limits).
public struct UsageLimit: Codable, Equatable, Sendable {
    public var kind: String          // "session", "weekly_all", "weekly_scoped", …
    public var group: String         // "session" or "weekly"
    public var percent: Double       // % used
    public var resetsAt: Date?
    public var scope: String?        // model name for per-model limits
    public var isActive: Bool        // the limit currently holding the account back

    public init(kind: String, group: String, percent: Double, resetsAt: Date?, scope: String?, isActive: Bool) {
        self.kind = kind; self.group = group; self.percent = percent
        self.resetsAt = resetsAt; self.scope = scope; self.isActive = isActive
    }

    public var title: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Weekly"
        default:
            if group == "session" { return scope.map { "Session · \($0)" } ?? "Session" }
            return scope.map { "Weekly · \($0)" } ?? "Weekly"
        }
    }

    public var isWeekly: Bool { group != "session" }
    public var window: UsageWindow { UsageWindow(utilization: percent, resetsAt: resetsAt) }

    /// % left; a limit whose reset time has passed is full again.
    public func left(now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 100 }
        return max(0, 100 - percent)
    }
}

public struct AccountUsage: Codable, Equatable, Sendable {
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var extra: ExtraUsage?
    public var fetchedAt: Date
    /// False when these are last-known numbers rather than a fresh fetch.
    public var isLive: Bool
    /// The limits that apply to this account (nil in numbers saved by older versions).
    public var limits: [UsageLimit]?

    public init(session: UsageWindow?, weekly: UsageWindow?, extra: ExtraUsage?, fetchedAt: Date, isLive: Bool,
                limits: [UsageLimit]? = nil) {
        self.session = session; self.weekly = weekly; self.extra = extra
        self.fetchedAt = fetchedAt; self.isLive = isLive; self.limits = limits
    }
}

public extension AccountUsage {
    /// The limits to show: the service's own list when present, else the session/weekly windows.
    var displayLimits: [UsageLimit] {
        if let limits, !limits.isEmpty {
            let order = ["session": 0, "weekly_all": 1]
            return limits.enumerated().sorted {
                (order[$0.element.kind] ?? 2, $0.offset) < (order[$1.element.kind] ?? 2, $1.offset)
            }.map(\.element)
        }
        var derived: [UsageLimit] = []
        if let s = session {
            derived.append(UsageLimit(kind: "session", group: "session", percent: s.utilization, resetsAt: s.resetsAt, scope: nil, isActive: false))
        }
        if let w = weekly {
            derived.append(UsageLimit(kind: "weekly_all", group: "weekly", percent: w.utilization, resetsAt: w.resetsAt, scope: nil, isActive: false))
        }
        return derived
    }

    /// The limit that matters most: the one the service marks as binding, else the one with least left.
    func primaryLimit(now: Date) -> UsageLimit? {
        let limits = displayLimits
        if let active = limits.first(where: { $0.isActive && ($0.resetsAt.map { $0 > now } ?? true) }) {
            return active
        }
        return limits.min { $0.left(now: now) < $1.left(now: now) }
    }

    /// The least % left across all limits (100 when nothing is known).
    func tightestLeft(now: Date) -> Double {
        displayLimits.map { $0.left(now: now) }.min() ?? 100
    }
}

public extension ExtraUsage {
    /// Formats an amount in minor units, e.g. 1240 with 2 decimal places in EUR → "€12.40".
    func formatted(_ amount: Double) -> String {
        let value = amount / pow(10, Double(decimalPlaces))
        guard let currency else { return String(format: "%.\(decimalPlaces)f", value) }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = decimalPlaces
        f.maximumFractionDigits = decimalPlaces
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

public enum UsageParser {
    private struct Window: Decodable {
        var utilization: Double?
        var resets_at: String?
    }

    private struct Extra: Decodable {
        var is_enabled: Bool?
        var monthly_limit: Double?
        var used_credits: Double?
        var utilization: Double?
        var currency: String?
        var decimal_places: Int?
        var spend_limit_reached: Bool?
    }

    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { var display_name: String? }
            var model: Model?
        }
        var kind: String?
        var group: String?
        var percent: Double?
        var resets_at: String?
        var scope: Scope?
        var is_active: Bool?
    }

    private struct Body: Decodable {
        var five_hour: Window?
        var seven_day: Window?
        var extra_usage: Extra?
        var limits: [Limit]?
    }

    private struct Cache: Decodable {
        var fetchedAtMs: Double?
        var accountUuid: String?
    }

    private struct ClaudeJSONCache: Decodable {
        var cachedUsageUtilization: Cache?
    }

    /// Parses the usage endpoint body (same shape as Claude Code's cached `utilization`).
    public static func parse(_ data: Data, fetchedAt: Date) throws -> AccountUsage {
        let body = try JSONDecoder().decode(Body.self, from: data)
        let limits = body.limits?.compactMap { l -> UsageLimit? in
            guard let kind = l.kind, let percent = l.percent else { return nil }
            return UsageLimit(kind: kind, group: l.group ?? (kind.hasPrefix("session") ? "session" : "weekly"),
                              percent: percent, resetsAt: l.resets_at.flatMap(date),
                              scope: l.scope?.model?.display_name, isActive: l.is_active ?? false)
        }
        return AccountUsage(session: window(body.five_hour), weekly: window(body.seven_day),
                            extra: body.extra_usage.map(extra), fetchedAt: fetchedAt, isLive: true, limits: limits)
    }

    /// Reads Claude Code's own usage cache from `~/.claude.json`, if it belongs to `accountUuid`.
    public static func parseCache(_ claudeJSONData: Data, accountUuid: String) -> AccountUsage? {
        guard let meta = try? JSONDecoder().decode(ClaudeJSONCache.self, from: claudeJSONData).cachedUsageUtilization,
              meta.accountUuid == accountUuid,
              let root = try? JSONSerialization.jsonObject(with: claudeJSONData) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"],
              let data = try? JSONSerialization.data(withJSONObject: utilization),
              var usage = try? parse(data, fetchedAt: Date(timeIntervalSince1970: (meta.fetchedAtMs ?? 0) / 1000))
        else { return nil }
        usage.isLive = false
        return usage
    }

    private static func window(_ w: Window?) -> UsageWindow? {
        guard let w, let u = w.utilization else { return nil }
        return UsageWindow(utilization: u, resetsAt: w.resets_at.flatMap(date))
    }

    private static func extra(_ e: Extra) -> ExtraUsage {
        ExtraUsage(isEnabled: e.is_enabled ?? false, monthlyLimit: e.monthly_limit, usedCredits: e.used_credits,
                   utilization: e.utilization, currency: e.currency, decimalPlaces: e.decimal_places ?? 2,
                   spendLimitReached: e.spend_limit_reached ?? false)
    }

    static func date(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}
