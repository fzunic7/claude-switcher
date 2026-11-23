import Foundation

public enum UsageDisplayMode: String, CaseIterable, Sendable {
    case remaining, used
}

public enum UsageDisplay {
    /// Menu-bar text for the limit that matters most, e.g. "main 70% left" or "it 60% left · week".
    public static func menuBarTitle(label: String, usage: AccountUsage?, mode: UsageDisplayMode, now: Date = Date()) -> String {
        guard let limit = usage?.primaryLimit(now: now) else { return "\(label) –" }
        let left = limit.left(now: now)
        let suffix = limit.isWeekly ? " · week" : ""
        switch mode {
        case .remaining: return "\(label) \(Int(left.rounded()))% left\(suffix)"
        case .used: return "\(label) \(Int((100 - left).rounded()))% used\(suffix)"
        }
    }
}
