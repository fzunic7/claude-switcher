import Foundation

public enum UsageDisplayMode: String, CaseIterable, Sendable {
    case remaining, used
}

public enum UsageDisplay {
    /// Session (5-hour) % used. A missing window while other numbers are known means the session hasn't started: 0.
    public static func sessionUsed(_ usage: AccountUsage?) -> Double? {
        guard let usage else { return nil }
        return usage.session?.utilization ?? 0
    }

    public static func menuBarTitle(label: String, usage: AccountUsage?, mode: UsageDisplayMode) -> String {
        guard let used = sessionUsed(usage) else { return "\(label) –" }
        switch mode {
        case .remaining: return "\(label) \(Int(max(0, 100 - used).rounded()))% left"
        case .used: return "\(label) \(Int(used.rounded()))% used"
        }
    }
}
