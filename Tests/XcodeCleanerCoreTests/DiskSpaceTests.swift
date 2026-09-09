import XCTest
@testable import XcodeCleanerCore

final class DiskSpaceTests: XCTestCase {
    func test_usedIsTotalMinusAvailable() {
        let space = DiskSpace(total: 1000, available: 250)
        XCTAssertEqual(space.used, 750)
    }

    func test_currentHomeVolumeHasSaneNumbers() throws {
        let space = try DiskSpace.current()
        XCTAssertGreaterThan(space.total, 0)
        XCTAssertLessThanOrEqual(space.available, space.total)
    }
}
