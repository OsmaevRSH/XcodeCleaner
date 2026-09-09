import XCTest
@testable import XcodeCleanerCore

final class RunningAppsCheckTests: XCTestCase {
    func test_reportsRunningProcessesByName() async {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "")
        runner.respond(to: "pgrep -x Xcode", stdout: "123")
        runner.respond(to: "pgrep -x xcodebuild", stdout: "456")
        let check = RunningAppsCheck(runner: runner)

        let running = await check.blockingProcesses()

        XCTAssertEqual(running, ["Xcode", "xcodebuild"])
        XCTAssertEqual(runner.callLines, [
            "pgrep -x Xcode", "pgrep -x Simulator", "pgrep -x xcodebuild", "pgrep -x xctest",
        ])
    }

    func test_emptyWhenNothingRuns() async {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "")
        let check = RunningAppsCheck(runner: runner)

        let running = await check.blockingProcesses()

        XCTAssertEqual(running, [])
    }
}
