import XCTest
@testable import XcodeCleanerCore

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
        XCTAssertEqual(collector.lines.sorted(), ["one", "two"])
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
}
