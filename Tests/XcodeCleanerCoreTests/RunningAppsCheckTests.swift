import XCTest
@testable import XcodeCleanerCore

final class RunningAppsCheckTests: XCTestCase {
    func test_reportsRunningProcessesByName() async throws {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "")
        runner.respond(to: "pgrep -x Xcode", stdout: "123")
        runner.respond(to: "pgrep -x xcodebuild", stdout: "456")
        let check = RunningAppsCheck(runner: runner)

        let running = try await check.blockingProcesses()

        XCTAssertEqual(running, ["Xcode", "xcodebuild"])
        XCTAssertEqual(runner.callLines, [
            "pgrep -x Xcode", "pgrep -x Simulator", "pgrep -x xcodebuild", "pgrep -x xctest",
        ])
    }

    func test_emptyWhenNothingRuns() async throws {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "")
        let check = RunningAppsCheck(runner: runner)

        let running = try await check.blockingProcesses()

        XCTAssertEqual(running, [])
    }

    func test_pgrepErrorIsThrown() async {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 2, stdout: "", stderr: "usage: pgrep")
        let check = RunningAppsCheck(runner: runner)

        do {
            _ = try await check.blockingProcesses()
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.executable, "pgrep")
            XCTAssertTrue(error.message.contains("usage: pgrep"), "unexpected \(error.message)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_runnerErrorIsThrown() async {
        let runner = FakeCommandRunner()
        runner.errorToThrow = CommandError(executable: "pgrep", message: "spawn failed")
        let check = RunningAppsCheck(runner: runner)

        do {
            _ = try await check.blockingProcesses()
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.message, "spawn failed")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_pgrepKilledBySignalIsThrown() async {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "", terminatedBySignal: true)
        let check = RunningAppsCheck(runner: runner)

        do {
            _ = try await check.blockingProcesses()
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.executable, "pgrep")
            XCTAssertEqual(error.message, "killed by signal 1")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
