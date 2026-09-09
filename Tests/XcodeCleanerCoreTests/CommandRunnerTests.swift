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

final class CommandRunnerTests: XCTestCase {
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

    func test_cancellationTerminatesProcess() async throws {
        let runner = ProcessCommandRunner()
        let task = Task { try await runner.run("sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let started = Date()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
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
}
