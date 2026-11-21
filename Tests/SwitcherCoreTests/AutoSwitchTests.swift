import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AutoSwitchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func p(_ id: String) -> Profile {
        Profile(id: id, label: id, role: .backup, orgUuid: "o", email: "\(id)@x", oauthAccount: [:], hasDesktopSnapshot: true)
    }

    func u(session: Double?, weekly: Double? = 10, resets: Date? = nil, age: TimeInterval = 0) -> AccountUsage {
        AccountUsage(session: session.map { UsageWindow(utilization: $0, resetsAt: resets) },
                     weekly: weekly.map { UsageWindow(utilization: $0, resetsAt: nil) }, extra: nil,
                     fetchedAt: now.addingTimeInterval(-age), isLive: age == 0)
    }

    func decide(_ usage: [String: AccountUsage], profiles: [String] = ["A", "B", "C"], last: Date? = nil) -> String? {
        AutoSwitch.target(activeId: "A", candidates: profiles.map(p), usage: usage, lastAutoSwitch: last, now: now)
    }

    @Test func switchesAtFivePercentLeft() {
        #expect(decide(["A": u(session: 95), "B": u(session: 10)]) == "B")
    }

    @Test func staysAboveThreshold() {
        #expect(decide(["A": u(session: 94), "B": u(session: 10)]) == nil)
    }

    @Test func weeklyLimitAlsoTriggers() {
        #expect(decide(["A": u(session: 20, weekly: 96), "B": u(session: 10)]) == "B")
    }

    @Test func picksAccountWithMostSessionLeft() {
        #expect(decide(["A": u(session: 99), "B": u(session: 60), "C": u(session: 5)]) == "C")
    }

    @Test func needsATargetWithAtLeastTwentyPercentLeft() {
        #expect(decide(["A": u(session: 99), "B": u(session: 85), "C": u(session: 90)]) == nil)
    }

    @Test func targetWithExhaustedWeeklyIsSkipped() {
        #expect(decide(["A": u(session: 99), "B": u(session: 0, weekly: 97)]) == nil)
    }

    @Test func passedResetCountsAsFull() {
        let old = u(session: 100, resets: now.addingTimeInterval(-60), age: 3 * 3600)
        #expect(decide(["A": u(session: 99), "B": old]) == "B")
    }

    @Test func staleActiveNumbersDoNotTrigger() {
        #expect(decide(["A": u(session: 99, age: 20 * 60), "B": u(session: 0)]) == nil)
    }

    @Test func unknownTargetIsSkipped() {
        #expect(decide(["A": u(session: 99)]) == nil)
    }

    @Test func cooldownAfterAnAutoSwitch() {
        #expect(decide(["A": u(session: 99), "B": u(session: 0)], last: now.addingTimeInterval(-10 * 60)) == nil)
        #expect(decide(["A": u(session: 99), "B": u(session: 0)], last: now.addingTimeInterval(-31 * 60)) == "B")
    }
}
