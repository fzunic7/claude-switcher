import Foundation

/// Decides when to switch automatically: the active account is nearly out (session or weekly) and another
/// account clearly has room.
public enum AutoSwitch {
    public static let triggerLeft: Double = 5          // % left on the active account
    public static let minimumTargetLeft: Double = 20   // % session left the target must have
    public static let maxAge: TimeInterval = 15 * 60   // active account's numbers must be this fresh
    public static let cooldown: TimeInterval = 30 * 60 // between automatic switches

    /// The account to switch to, or nil to stay.
    public static func target(activeId: String, candidates: [Profile], usage: [String: AccountUsage],
                              lastAutoSwitch: Date?, now: Date) -> String? {
        if let last = lastAutoSwitch, now.timeIntervalSince(last) < cooldown { return nil }
        guard let active = usage[activeId], now.timeIntervalSince(active.fetchedAt) <= maxAge else { return nil }
        let nearlyOut = left(active.session, now) <= triggerLeft || left(active.weekly, now) <= triggerLeft
        guard nearlyOut else { return nil }

        return bestTarget(activeId: activeId, candidates: candidates, usage: usage, now: now)
    }

    /// The other account with the most session left (at least `minimumTargetLeft`, weekly not exhausted).
    public static func bestTarget(activeId: String, candidates: [Profile], usage: [String: AccountUsage],
                                  now: Date) -> String? {
        let options = candidates.filter { $0.id != activeId }.compactMap { p -> (String, Double)? in
            guard let u = usage[p.id] else { return nil }
            let session = left(u.session, now)
            guard session >= minimumTargetLeft, left(u.weekly, now) > triggerLeft else { return nil }
            return (p.id, session)
        }
        return options.max { $0.1 < $1.1 }?.0
    }

    /// % left in a window; a window whose reset time has passed (or that hasn't started) is full.
    public static func left(_ window: UsageWindow?, _ now: Date) -> Double {
        guard let window else { return 100 }
        if let reset = window.resetsAt, reset <= now { return 100 }
        return max(0, 100 - window.utilization)
    }
}
