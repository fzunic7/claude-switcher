import Foundation
import Testing
@testable import SwitcherCore

@Suite struct RunningClaudeTests {
    @Test func countParsesPgrepOutput() throws {
        let runner = RecordingRunner()
        runner.responses = [(0, "123\n456\n")]
        #expect(try RunningClaude(runner: runner).cliProcessCount() == 2)
        #expect(runner.calls[0].path == "/usr/bin/pgrep" && runner.calls[0].args == ["-x", "claude"])
    }

    @Test func countIsZeroWhenPgrepExits1() throws {
        let runner = RecordingRunner()
        runner.responses = [(1, "")]
        #expect(try RunningClaude(runner: runner).cliProcessCount() == 0)
    }
}
