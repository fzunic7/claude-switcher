import Foundation
import Testing
@testable import SwitcherCore

let maxPlanJSON = #"{"five_hour":null,"seven_day":{"utilization":40,"resets_at":"2026-11-29T11:00:00.692334+00:00"},"limits":[{"kind":"weekly_all","group":"weekly","percent":40,"severity":"normal","resets_at":"2026-11-29T11:00:00.692334+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":92,"severity":"warning","resets_at":"2026-11-29T10:59:59.692443+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}"#

let teamPlanJSON = #"{"five_hour":{"utilization":83,"resets_at":"2026-11-23T13:00:00Z"},"seven_day":{"utilization":14,"resets_at":"2026-11-30T05:00:00Z"},"limits":[{"kind":"session","group":"session","percent":83,"resets_at":"2026-11-23T13:00:00Z","scope":null,"is_active":true},{"kind":"weekly_all","group":"weekly","percent":14,"resets_at":"2026-11-30T05:00:00Z","scope":null,"is_active":false}]}"#

@Suite struct UsageLimitsTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)   // before all resets

    @Test func parsesMaxPlanLimitsWithoutASession() throws {
        let u = try UsageParser.parse(Data(maxPlanJSON.utf8), fetchedAt: now)
        #expect(u.displayLimits.map(\.title) == ["Weekly", "Weekly · Fable"])
        #expect(u.displayLimits.map(\.percent) == [40, 92])
        #expect(u.displayLimits.first?.isActive == true)
    }

    @Test func parsesTeamPlanLimits() throws {
        let u = try UsageParser.parse(Data(teamPlanJSON.utf8), fetchedAt: now)
        #expect(u.displayLimits.map(\.title) == ["Session", "Weekly"])
    }

    @Test func withoutALimitsListFallsBackToWindows() {
        let u = AccountUsage(session: UsageWindow(utilization: 30, resetsAt: nil), weekly: UsageWindow(utilization: 5, resetsAt: nil),
                             extra: nil, fetchedAt: now, isLive: true)
        #expect(u.displayLimits.map(\.title) == ["Session", "Weekly"])
    }

    @Test func primaryIsTheBindingLimit() throws {
        let u = try UsageParser.parse(Data(maxPlanJSON.utf8), fetchedAt: now)
        #expect(u.primaryLimit(now: now)?.title == "Weekly")
    }

    @Test func primaryFallsBackToTheMostUsed() {
        let u = AccountUsage(session: UsageWindow(utilization: 30, resetsAt: nil), weekly: UsageWindow(utilization: 50, resetsAt: nil),
                             extra: nil, fetchedAt: now, isLive: true)
        #expect(u.primaryLimit(now: now)?.title == "Weekly")
    }

    @Test func menuBarUsesTheBindingLimitAndSaysWhenItIsWeekly() throws {
        let max = try UsageParser.parse(Data(maxPlanJSON.utf8), fetchedAt: now)
        #expect(UsageDisplay.menuBarTitle(label: "it", usage: max, mode: .remaining, now: now) == "it 60% left · week")
        let team = try UsageParser.parse(Data(teamPlanJSON.utf8), fetchedAt: now)
        #expect(UsageDisplay.menuBarTitle(label: "frane", usage: team, mode: .remaining, now: now) == "frane 17% left")
    }

    @Test func storedUsageWithoutLimitsStillDecodes() throws {
        let old = #"{"session":{"utilization":10},"fetchedAt":0,"isLive":true}"#
        let u = try JSONDecoder().decode(AccountUsage.self, from: Data(old.utf8))
        #expect(u.limits == nil)
    }

    @Test func autoSwitchSeesAnExhaustedModelLimit() throws {
        func p(_ id: String) -> Profile {
            Profile(id: id, label: id, role: .backup, orgUuid: "o", email: id, oauthAccount: [:], hasDesktopSnapshot: true)
        }
        var active = try UsageParser.parse(Data(maxPlanJSON.utf8), fetchedAt: now)
        active.limits?[1].percent = 96                                   // Fable weekly nearly out
        let other = try UsageParser.parse(Data(teamPlanJSON.utf8).replacing(Data("83".utf8), with: Data("10".utf8)), fetchedAt: now)
        #expect(AutoSwitch.target(activeId: "A", candidates: [p("A"), p("B")], usage: ["A": active, "B": other],
                                  lastAutoSwitch: nil, now: now) == "B")
    }

    @Test func lowUsageAlertNamesTheLimit() throws {
        var u = try UsageParser.parse(Data(maxPlanJSON.utf8), fetchedAt: now)
        u.limits?[1].percent = 93
        let alert = LowUsageAlert.check(accountId: "A", usage: u, now: now)
        #expect(alert?.title == "Weekly · Fable")
        #expect(alert?.left == 7)
    }
}
