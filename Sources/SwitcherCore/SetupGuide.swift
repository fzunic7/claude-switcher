import Foundation

/// The first-run checklist: what still needs doing for switching to cover CLI, VS Code and Claude Desktop.
public enum SetupGuide {
    public enum Kind: Equatable, Sendable {
        case installClaudeCode
        case addMain
        case addBackup
        /// Claude Desktop signed in once as this account (nil before any account exists).
        case desktopSignIn(String?)
        case vsCode
    }

    public struct Step: Equatable, Sendable {
        public let kind: Kind
        public let done: Bool
    }

    public static func steps(state: SwitcherState, claudeInstalled: Bool, desktopAccountId: String?) -> [Step] {
        var steps = [
            Step(kind: .installClaudeCode, done: claudeInstalled),
            Step(kind: .addMain, done: !state.profiles.isEmpty),
            Step(kind: .addBackup, done: state.profiles.count >= 2),
        ]
        if state.profiles.isEmpty {
            steps.append(Step(kind: .desktopSignIn(nil), done: false))
        } else {
            let ordered = state.profiles.sorted { ($0.role == .main ? 0 : 1) < ($1.role == .main ? 0 : 1) }
            for p in ordered {
                // Signed in right now counts: its Desktop login is saved on the next switch.
                steps.append(Step(kind: .desktopSignIn(p.id), done: p.hasDesktopSnapshot || desktopAccountId == p.id))
            }
        }
        steps.append(Step(kind: .vsCode, done: true))   // uses Claude Code's login; nothing to set up
        return steps
    }

    public static func isComplete(_ steps: [Step]) -> Bool { steps.allSatisfy(\.done) }
}
