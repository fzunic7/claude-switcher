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
