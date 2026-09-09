import XCTest
@testable import XcodeCleanerCore

final class CleanupLogFileTests: XCTestCase {
    func test_appendsLinesToFileInDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let log = try CleanupLogFile(directory: temp.url, runID: "test-run")

        await log.append("first")
        await log.append("second")

        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "first\nsecond\n")
        XCTAssertEqual(log.fileURL.lastPathComponent, "cleanup-test-run.log")
    }

    func test_appendLineKeepsOrderOfSynchronousCalls() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let log = try CleanupLogFile(directory: temp.url, runID: "ordering")
        let expected = (0..<200).map { "line \($0)" }

        for line in expected {
            log.appendLine(line)
        }
        await log.close()

        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init), expected)
    }

    func test_closeIsIdempotent() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let log = try CleanupLogFile(directory: temp.url, runID: "close-twice")

        log.appendLine("only")
        await log.close()
        await log.close()

        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "only\n")
    }

    func test_defaultRunIDUsesSortableTimestamp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let runID = CleanupLogFile.defaultRunID(now: date)

        XCTAssertEqual(runID, formatter.string(from: date))
        XCTAssertNotNil(runID.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression))
    }

    func test_defaultDirectoryIsOnDesktop() {
        let directory = CleanupLogFile.defaultDirectory(home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(directory.path, "/Users/tester/Desktop/Xcode Cleanup Logs")
    }
}
