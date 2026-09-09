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
}
