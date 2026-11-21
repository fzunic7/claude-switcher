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

public struct AccountUsage: Codable, Equatable, Sendable {
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var extra: ExtraUsage?
    public var fetchedAt: Date
    /// False when these are last-known numbers rather than a fresh fetch.
    public var isLive: Bool

    public init(session: UsageWindow?, weekly: UsageWindow?, extra: ExtraUsage?, fetchedAt: Date, isLive: Bool) {
        self.session = session; self.weekly = weekly; self.extra = extra
        self.fetchedAt = fetchedAt; self.isLive = isLive
    }
}

public extension ExtraUsage {
    /// Formats an amount in minor units, e.g. 1240 with 2 decimal places in EUR → "€12.40".
    func formatted(_ amount: Double) -> String {
        let value = amount / pow(10, Double(decimalPlaces))
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency ?? "USD"
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

    private struct Body: Decodable {
        var five_hour: Window?
        var seven_day: Window?
        var extra_usage: Extra?
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
        return AccountUsage(session: window(body.five_hour), weekly: window(body.seven_day),
                            extra: body.extra_usage.map(extra), fetchedAt: fetchedAt, isLive: true)
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
