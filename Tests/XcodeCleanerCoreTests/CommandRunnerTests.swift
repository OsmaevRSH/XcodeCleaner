import XCTest
@testable import XcodeCleanerCore
#if canImport(Darwin)
import Darwin
#endif

/// `pwd` (via getcwd) reports the kernel-resolved canonical path, while `TemporaryDirectory.url`
/// keeps Foundation's special-cased `/var` (Foundation does not resolve `/var`, `/tmp`, `/etc`
/// through their `/private` symlinks). Compare against `realpath(3)` to match what the subprocess
/// actually observes.
private func canonicalPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return path }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

private final class OutcomeBox<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Success, Error>?

    var outcome: Result<Success, Error>? { lock.withLock { storage } }

    func store(_ value: Result<Success, Error>) {
        lock.withLock { storage = value }
    }
}

final class CommandRunnerTests: XCTestCase {
    /// Runs `body` on its own task and returns `nil` if it did not finish in time, so a
    /// regression that reintroduces a hang is reported as a failed test instead of freezing
    /// the whole suite.
    private func outcome<Success: Sendable>(
        within seconds: TimeInterval = 5,
        of body: @escaping @Sendable () async throws -> Success
    ) async -> Result<Success, Error>? {
        let box = OutcomeBox<Success>()
        let finished = expectation(description: "command finished")
        Task {
            do {
                box.store(.success(try await body()))
            } catch {
                box.store(.failure(error))
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: seconds)
        return box.outcome
    }

    private func assertThrows<Success>(
        _ outcome: Result<Success, Error>?,
        _ check: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case nil:
            XCTFail("did not finish within the timeout", file: file, line: line)
        case .success:
            XCTFail("expected a thrown error", file: file, line: line)
        case .failure(let error):
            check(error)
        }
    }

    func test_echoReturnsStdoutAndZeroExit() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run("echo", ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertTrue(result.succeeded)
    }

    func test_nonZeroExitCodeIsReported() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run("sh", ["-c", "echo err 1>&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderr, "err")
        XCTAssertFalse(result.succeeded)
    }

    func test_outputLinesAreStreamed() async throws {
        let runner = ProcessCommandRunner()
        let collector = LineCollector()
        _ = try await runner.run("sh", ["-c", "echo one; echo two"]) { line in
            collector.append(line)
        }
        XCTAssertEqual(collector.lines, ["one", "two"])
    }

    func test_missingExecutableThrows() async {
        let runner = ProcessCommandRunner()
        do {
            _ = try await runner.run("definitely-not-a-binary-xyz", [])
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.executable, "definitely-not-a-binary-xyz")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_locatorFindsBinaryInSearchDirectories() {
        let locator = ExecutableLocator(searchDirectories: ["/bin", "/usr/bin"])
        XCTAssertEqual(locator.resolve("ls"), "/bin/ls")
        XCTAssertNil(locator.resolve("no-such-binary-xyz"))
    }

    func test_locatorRejectsDirectoryPath() {
        XCTAssertNil(ExecutableLocator.standard.resolve("/tmp"))
        XCTAssertNil(ExecutableLocator.standard.resolve("/usr/bin"))
        XCTAssertEqual(ExecutableLocator.standard.resolve("/bin/ls"), "/bin/ls")
    }

    func test_currentDirectoryOverloadRunsInGivenDirectory() async throws {
        let runner = ProcessCommandRunner()
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let collector = LineCollector()

        let result = try await runner.run("pwd", [], currentDirectory: temp.url) { collector.append($0) }
        let expectedPath = canonicalPath(temp.url.path)

        XCTAssertEqual(result.stdout, expectedPath)
        XCTAssertEqual(collector.lines, [expectedPath])
    }

    func test_fakeRunnerRecordsCurrentDirectoryThroughOverload() async throws {
        let runner = FakeCommandRunner()
        _ = try await runner.run("arc", ["mount"], currentDirectory: URL(fileURLWithPath: "/tmp")) { _ in }
        XCTAssertEqual(runner.calls.first?.currentDirectory, "/tmp")
    }

    func test_largeOutputDoesNotDeadlock() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run("sh", ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -n 20000"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 20000)
    }

    func test_failureToLaunchThrowsInsteadOfHanging() async {
        let runner = ProcessCommandRunner()
        let missing = URL(fileURLWithPath: "/tmp/no-such-dir-\(UUID().uuidString)")
        let outcome = await outcome {
            try await runner.run("pwd", [], currentDirectory: missing) { _ in }
        }
        assertThrows(outcome) { error in
            XCTAssertTrue(error is CommandError, "unexpected \(error)")
        }
    }

    func test_cancellationTerminatesProcess() async throws {
        let runner = ProcessCommandRunner()
        let outcome = await outcome {
            let task = Task { try await runner.run("sleep", ["30"]) }
            try await Task.sleep(for: .milliseconds(300))
            task.cancel()
            return try await task.value
        }
        assertThrows(outcome) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
    }

    func test_cancellationRacingLaunchDoesNotCrash() async {
        let runner = ProcessCommandRunner()
        let outcome = await outcome {
            let task = Task { try await runner.run("sleep", ["30"]) }
            task.cancel()
            return try await task.value
        }
        assertThrows(outcome) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
    }

    func test_cancellationBeforeLaunchThrowsCancellationError() async {
        let runner = ProcessCommandRunner()
        let outcome = await outcome {
            let task = Task { () -> CommandResult in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return try await runner.run("sleep", ["30"])
            }
            task.cancel()
            return try await task.value
        }
        assertThrows(outcome) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
    }

    func test_terminationReasonIsReportedForSignalledProcess() async throws {
        let runner = ProcessCommandRunner()

        let normal = try await runner.run("sh", ["-c", "exit 0"])
        XCTAssertFalse(normal.terminatedBySignal)

        let signalled = try await runner.run("sh", ["-c", "kill -TERM $$; sleep 5"])
        XCTAssertTrue(signalled.terminatedBySignal)
        XCTAssertEqual(signalled.exitCode, 15)
    }

    func test_fakeRunnerCanThrow() async {
        let runner = FakeCommandRunner()
        runner.errorToThrow = CommandError(executable: "arc", message: "missing")
        do {
            _ = try await runner.run("arc", ["mount"])
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.message, "missing")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(runner.callLines, ["arc mount"])
    }

    func test_fakeRunnerStreamsStdoutAndStderrLines() async throws {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc mount", stdout: "one\ntwo", stderr: "bad")
        let collector = LineCollector()

        _ = try await runner.run("arc", ["mount"]) { collector.append($0) }

        XCTAssertEqual(collector.lines, ["one", "two", "bad"])
    }

    func test_fakeRunnerStreamsNothingForEmptyOutput() async throws {
        let runner = FakeCommandRunner()
        let collector = LineCollector()

        _ = try await runner.run("arc", ["mount"]) { collector.append($0) }

        XCTAssertEqual(collector.lines, [])
    }
}
