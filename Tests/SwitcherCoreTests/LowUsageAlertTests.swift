import Foundation
import Testing
@testable import SwitcherCore

@Suite struct LowUsageAlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = Date(timeIntervalSince1970: 1_800_003_600)

    func u(session: Double?, weekly: Double? = 10, age: TimeInterval = 0) -> AccountUsage {
        AccountUsage(session: session.map { UsageWindow(utilization: $0, resetsAt: reset) },
                     weekly: weekly.map { UsageWindow(utilization: $0, resetsAt: nil) }, extra: nil,
                     fetchedAt: now.addingTimeInterval(-age), isLive: age == 0)
    }

    @Test func firesAtTenPercentLeft() {
        let alert = LowUsageAlert.check(accountId: "A", usage: u(session: 90), now: now)
        #expect(alert?.window == .session)
        #expect(alert?.left == 10)
    }

    @Test func quietAboveThreshold() {
        #expect(LowUsageAlert.check(accountId: "A", usage: u(session: 89), now: now) == nil)
    }

    @Test func weeklyLimitAlsoAlerts() {
        #expect(LowUsageAlert.check(accountId: "A", usage: u(session: 20, weekly: 93), now: now)?.window == .weekly)
    }

    @Test func staleNumbersDoNotAlert() {
        #expect(LowUsageAlert.check(accountId: "A", usage: u(session: 99, age: 20 * 60), now: now) == nil)
    }

    @Test func keyIsStableWithinAWindowAndChangesAfterReset() {
        let a = LowUsageAlert.check(accountId: "A", usage: u(session: 91), now: now)
        let b = LowUsageAlert.check(accountId: "A", usage: u(session: 97), now: now)
        #expect(a?.key == b?.key)
        let later = AccountUsage(session: UsageWindow(utilization: 95, resetsAt: reset.addingTimeInterval(18_000)),
                                 weekly: nil, extra: nil, fetchedAt: now, isLive: true)
        #expect(LowUsageAlert.check(accountId: "A", usage: later, now: now)?.key != a?.key)
    }

    @Test func bestTargetHasTheMostSessionLeft() {
        func p(_ id: String) -> Profile {
            Profile(id: id, label: id, role: .backup, orgUuid: "o", email: id, oauthAccount: [:], hasDesktopSnapshot: true)
        }
        let usage = ["A": u(session: 95), "B": u(session: 50), "C": u(session: 10), "D": u(session: 90)]
        #expect(AutoSwitch.bestTarget(activeId: "A", candidates: ["A", "B", "C", "D"].map(p), usage: usage, now: now) == "C")
    }
}
