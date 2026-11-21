import Foundation
import Testing
@testable import SwitcherCore

@Suite struct UsageDisplayTests {
    let used30 = AccountUsage(session: UsageWindow(utilization: 30, resetsAt: nil), weekly: nil, extra: nil,
                              fetchedAt: Date(), isLive: true)
    let notStarted = AccountUsage(session: nil, weekly: UsageWindow(utilization: 34, resetsAt: nil), extra: nil,
                                  fetchedAt: Date(), isLive: true)

    @Test func remainingIsDefaultStyle() {
        #expect(UsageDisplay.menuBarTitle(label: "frane", usage: used30, mode: .remaining) == "frane 70% left")
    }

    @Test func usedStyle() {
        #expect(UsageDisplay.menuBarTitle(label: "frane", usage: used30, mode: .used) == "frane 30% used")
    }

    @Test func sessionNotStartedCountsAsZeroUsed() {
        #expect(UsageDisplay.menuBarTitle(label: "it", usage: notStarted, mode: .remaining) == "it 100% left")
        #expect(UsageDisplay.sessionUsed(notStarted) == 0)
    }

    @Test func unknownUsageShowsDash() {
        #expect(UsageDisplay.menuBarTitle(label: "it", usage: nil, mode: .remaining) == "it –")
    }

    @Test func remainingNeverNegative() {
        let over = AccountUsage(session: UsageWindow(utilization: 104, resetsAt: nil), weekly: nil, extra: nil,
                                fetchedAt: Date(), isLive: true)
        #expect(UsageDisplay.menuBarTitle(label: "x", usage: over, mode: .remaining) == "x 0% left")
    }
}
