import Foundation
import Testing
@testable import SwitcherCore

@Suite struct RunningClaudeTests {
    @Test func countIsZeroWhenPgrepExits1() throws {
        let runner = RecordingRunner()
        runner.responses = [(1, "")]
        #expect(try RunningClaude(runner: runner).cliProcessCount() == 0)
    }

    @Test func countsNativeAndNodeInstalls() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, "1 /Users/me/.local/bin/claude\n2 node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n3 /usr/bin/vim claude.txt\n4 /Applications/Claude.app/Contents/MacOS/Claude\n")]
        #expect(try RunningClaude(runner: runner).cliProcessCount() == 2)
    }
}
