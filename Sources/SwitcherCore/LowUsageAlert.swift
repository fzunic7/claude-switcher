import Foundation

/// When to warn that the active account is running low on any of its limits.
public enum LowUsageAlert {
    public static let threshold: Double = 10           // % left
    public static let maxAge: TimeInterval = 15 * 60   // only fresh numbers count

    public struct Alert: Equatable, Sendable {
        public let title: String      // e.g. "Session", "Weekly · Fable"
        public let left: Double
        /// Same for the whole limit window, so each window is announced once.
        public let key: String
    }

    public static func check(accountId: String, usage: AccountUsage?, now: Date) -> Alert? {
        guard let usage, now.timeIntervalSince(usage.fetchedAt) <= maxAge else { return nil }
        let low = usage.displayLimits
            .map { ($0, $0.left(now: now)) }
            .filter { $0.1 <= threshold }
            .min { $0.1 < $1.1 }
        guard let (limit, left) = low else { return nil }
        let resetPart = limit.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
        return Alert(title: limit.title, left: left,
                     key: "\(accountId)|\(limit.kind)|\(limit.scope ?? "")|\(resetPart)")
    }
}
