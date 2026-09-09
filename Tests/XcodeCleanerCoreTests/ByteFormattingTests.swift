import XCTest
@testable import XcodeCleanerCore

final class ByteFormattingTests: XCTestCase {
    func test_zeroBytes() {
        XCTAssertEqual(ByteFormatting.string(0), "0 B")
    }

    func test_kilobytesWithTwoDecimals() {
        XCTAssertEqual(ByteFormatting.string(1536), "1.50 KB")
    }

    func test_gigabytes() {
        XCTAssertEqual(ByteFormatting.string(5_261_334_937), "4.90 GB")
    }

    func test_negativeValueKeepsSign() {
        XCTAssertEqual(ByteFormatting.string(-1024), "-1.00 KB")
    }

    func test_justBelowBoundaryPromotesUnit() {
        XCTAssertEqual(ByteFormatting.string(1_073_741_823), "1.00 GB")
        XCTAssertEqual(ByteFormatting.string(1_048_570), "1.00 MB")
    }
}
