import Foundation

/// When to warn that the active account is running low.
public enum LowUsageAlert {
    public static let threshold: Double = 10           // % left
    public static let maxAge: TimeInterval = 15 * 60   // only fresh numbers count

    public enum Window: String, Sendable { case session, weekly }

    public struct Alert: Equatable, Sendable {
        public let window: Window
        public let left: Double
        /// Same for the whole limit window, so each window is announced once.
        public let key: String
    }

    public static func check(accountId: String, usage: AccountUsage?, now: Date) -> Alert? {
        guard let usage, now.timeIntervalSince(usage.fetchedAt) <= maxAge else { return nil }
        for (window, value) in [(Window.session, usage.session), (.weekly, usage.weekly)] {
            guard let value else { continue }
            let left = AutoSwitch.left(value, now)
            guard left <= threshold else { continue }
            let resetPart = value.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
            return Alert(window: window, left: left, key: "\(accountId)|\(window.rawValue)|\(resetPart)")
        }
        return nil
    }
}
