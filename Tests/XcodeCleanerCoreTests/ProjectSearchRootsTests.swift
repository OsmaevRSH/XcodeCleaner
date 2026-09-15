import XCTest
@testable import XcodeCleanerCore

final class ProjectSearchRootsTests: XCTestCase {
    private func roots(_ lines: [String]) -> [String] {
        CachePaths.normalizedSearchRoots(lines).roots
    }

    private func rejected(_ lines: [String]) -> [(line: String, reason: String)] {
        CachePaths.normalizedSearchRoots(lines).rejected
    }

    func test_trimsSpacesAndSurroundingSlashes() {
        XCTAssertEqual(roots(["  mobile/saft/ios  "]), ["mobile/saft/ios"])
        XCTAssertEqual(roots(["/mobile/saft/ios/"]), ["mobile/saft/ios"])
        XCTAssertEqual(roots(["\t//mobile/saft/ios// "]), ["mobile/saft/ios"])
    }

    func test_dropsBlankLinesWithoutCallingThemErrors() {
        let result = CachePaths.normalizedSearchRoots(["mobile/saft/ios", "", "   ", "\t"])

        XCTAssertEqual(result.roots, ["mobile/saft/ios"])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_emptyInputYieldsNoRoots() {
        let result = CachePaths.normalizedSearchRoots([])

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_rejectsLineThatNamesNothing() {
        let result = CachePaths.normalizedSearchRoots(["/", " // "])

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertEqual(result.rejected.map(\.reason), ["пустая строка", "пустая строка"])
        XCTAssertEqual(result.rejected.map(\.line), ["/", " // "])
    }

    func test_rejectsPathLeavingTheMount() {
        let lines = ["..", "../mobile", "mobile/../../etc", "mobile/saft/ios/.."]
        let result = CachePaths.normalizedSearchRoots(lines)

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertEqual(result.rejected.map(\.line), lines)
        XCTAssertEqual(
            result.rejected.map(\.reason),
            Array(repeating: "путь наружу из маунта", count: lines.count)
        )
    }

    func test_keepsDirectoriesWhoseNameOnlyLooksLikeAParent() {
        XCTAssertEqual(roots(["mobile/.../ios", "..build"]), ["mobile/.../ios", "..build"])
    }

    func test_keepsOrder() {
        XCTAssertEqual(
            roots(["mobile/music/ios", "mobile/saft/ios", "kinopoisk"]),
            ["mobile/music/ios", "mobile/saft/ios", "kinopoisk"]
        )
    }

    func test_removesDuplicates() {
        let result = CachePaths.normalizedSearchRoots([
            "mobile/saft/ios",
            "/mobile/saft/ios",
            " mobile/saft/ios ",
            "mobile/music/ios",
        ])

        XCTAssertEqual(result.roots, ["mobile/saft/ios", "mobile/music/ios"])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_keepsTheValidPartOfAMixedList() {
        let result = CachePaths.normalizedSearchRoots(["mobile/saft/ios", "../escape", "", "tools/"])

        XCTAssertEqual(result.roots, ["mobile/saft/ios", "tools"])
        XCTAssertEqual(result.rejected.map(\.line), ["../escape"])
    }
}
