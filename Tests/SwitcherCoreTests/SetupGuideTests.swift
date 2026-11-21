import Foundation
import Testing
@testable import SwitcherCore

@Suite struct SetupGuideTests {
    func profile(_ id: String, _ role: ProfileRole, desktop: Bool) -> Profile {
        Profile(id: id, label: id, role: role, orgUuid: "o", email: "\(id)@x", oauthAccount: [:], hasDesktopSnapshot: desktop)
    }

    @Test func freshInstallNeedsEverything() {
        let steps = SetupGuide.steps(state: SwitcherState(), claudeInstalled: false, desktopAccountId: nil)
        #expect(steps.map(\.kind) == [.installClaudeCode, .addMain, .addBackup, .desktopSignIn(nil), .vsCode])
        #expect(steps.filter(\.done).map(\.kind) == [.vsCode])
        #expect(!SetupGuide.isComplete(steps))
    }

    @Test func installedWithOneAccount() {
        let state = SwitcherState(profiles: [profile("A", .main, desktop: false)], activeId: "A")
        let steps = SetupGuide.steps(state: state, claudeInstalled: true, desktopAccountId: nil)
        #expect(steps.first { $0.kind == .installClaudeCode }?.done == true)
        #expect(steps.first { $0.kind == .addMain }?.done == true)
        #expect(steps.first { $0.kind == .addBackup }?.done == false)
    }

    @Test func oneDesktopStepPerAccountDoneWhenSavedOrSignedInNow() {
        let state = SwitcherState(profiles: [profile("A", .main, desktop: true), profile("B", .backup, desktop: false),
                                             profile("C", .backup, desktop: false)], activeId: "A")
        let steps = SetupGuide.steps(state: state, claudeInstalled: true, desktopAccountId: "B")
        let desktop = steps.filter { if case .desktopSignIn = $0.kind { return true } else { return false } }
        #expect(desktop.map(\.kind) == [.desktopSignIn("A"), .desktopSignIn("B"), .desktopSignIn("C")])
        #expect(desktop.map(\.done) == [true, true, false])     // B is signed in to Desktop right now
    }

    @Test func completeWhenAllDone() {
        let state = SwitcherState(profiles: [profile("A", .main, desktop: true), profile("B", .backup, desktop: true)], activeId: "A")
        #expect(SetupGuide.isComplete(SetupGuide.steps(state: state, claudeInstalled: true, desktopAccountId: "A")))
    }
}
