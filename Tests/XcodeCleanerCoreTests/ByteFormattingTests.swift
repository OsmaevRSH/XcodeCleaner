import XCTest
@testable import XcodeCleanerCore

final class ByteFormattingTests: XCTestCase {
    func test_zeroBytes() {
        XCTAssertEqual(ByteFormatting.string(0), "0 Б")
    }

    func test_smallValuesKeepOneDecimal() {
        XCTAssertEqual(ByteFormatting.string(1536), "1,5 КБ")
    }

    func test_gigabytes() {
        XCTAssertEqual(ByteFormatting.string(5_261_334_937), "4,9 ГБ")
    }

    func test_largeValuesDropDecimals() {
        XCTAssertEqual(ByteFormatting.string(195_000_000_000), "182 ГБ")
    }

    func test_negativeValueKeepsSign() {
        XCTAssertEqual(ByteFormatting.string(-1024), "-1,0 КБ")
    }

    func test_justBelowBoundaryPromotesUnit() {
        XCTAssertEqual(ByteFormatting.string(1_073_741_823), "1,0 ГБ")
        XCTAssertEqual(ByteFormatting.string(1_048_570), "1,0 МБ")
    }
}
