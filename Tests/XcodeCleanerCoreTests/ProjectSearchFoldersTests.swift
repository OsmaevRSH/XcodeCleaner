import XCTest
@testable import XcodeCleanerCore

final class ProjectSearchFoldersTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    private func folders(_ lines: [String]) -> [String] {
        CachePaths.normalizedSearchFolders(lines, home: home).folders.map(\.path)
    }

    private func rejected(_ lines: [String]) -> [(line: String, reason: String)] {
        CachePaths.normalizedSearchFolders(lines, home: home).rejected
    }

    func test_expandsTilde() {
        XCTAssertEqual(folders(["~"]), ["/Users/tester"])
        XCTAssertEqual(folders(["~/"]), ["/Users/tester"])
        XCTAssertEqual(folders(["~/Developer/MyLib"]), ["/Users/tester/Developer/MyLib"])
    }

    func test_dropsTrailingSlashesAndStandardizes() {
        XCTAssertEqual(folders(["/Users/tester/Developer/"]), ["/Users/tester/Developer"])
        XCTAssertEqual(folders(["/Users/tester/Developer//"]), ["/Users/tester/Developer"])
        XCTAssertEqual(folders(["/Users/tester/./Developer/x/.."]), ["/Users/tester/Developer"])
        XCTAssertEqual(folders(["  /Users/tester/Developer  "]), ["/Users/tester/Developer"])
    }

    func test_removesDuplicatesAndKeepsOrder() {
        let result = CachePaths.normalizedSearchFolders(
            [
                "/Volumes/Work",
                "~/Developer",
                "/Users/tester/Developer/",
                " ~/Developer ",
                "/Users/tester/Projects",
                "/Volumes/Work",
            ],
            home: home
        )

        XCTAssertEqual(
            result.folders.map(\.path),
            ["/Volumes/Work", "/Users/tester/Developer", "/Users/tester/Projects"]
        )
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_dropsBlankLinesWithoutCallingThemErrors() {
        let result = CachePaths.normalizedSearchFolders(["", "  ", "\t", "~/Developer"], home: home)

        XCTAssertEqual(result.folders.map(\.path), ["/Users/tester/Developer"])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_rejectsTheWholeDisk() {
        let result = CachePaths.normalizedSearchFolders(["/", "//", "/Users/.."], home: home)

        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertEqual(result.rejected.map(\.line), ["/", "//", "/Users/.."])
        XCTAssertEqual(result.rejected.map(\.reason), Array(repeating: "это весь диск", count: 3))
    }

    func test_rejectsEverySystemRoot() {
        let roots = ["/System", "/Library", "/Applications", "/usr", "/private", "/bin", "/sbin", "/opt"]

        let result = CachePaths.normalizedSearchFolders(roots, home: home)

        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertEqual(result.rejected.map(\.line), roots)
        XCTAssertEqual(result.rejected.map(\.reason), Array(repeating: "системная папка", count: roots.count))
    }

    /// The same folder spelled differently is still the same folder: the check runs on the
    /// normalised path, and the filesystem these live on ignores case.
    func test_rejectsSystemRootsHoweverTheyAreSpelled() {
        let lines = ["/System/", "/usr/local/..", "/LIBRARY", "/Applications//"]

        XCTAssertEqual(rejected(lines).map(\.reason), Array(repeating: "системная папка", count: lines.count))
    }

    /// Only the system roots themselves are refused: a project may well live under one of them.
    func test_keepsFoldersInsideSystemRoots() {
        XCTAssertEqual(folders(["/opt/src", "/usr/local/src"]), ["/opt/src", "/usr/local/src"])
    }

    func test_rejectsRelativePaths() {
        let lines = ["Developer", "./Developer", "../Developer", "~tester/Developer"]

        let result = CachePaths.normalizedSearchFolders(lines, home: home)

        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertEqual(result.rejected.map(\.line), lines)
        XCTAssertEqual(result.rejected.map(\.reason), Array(repeating: "нужен полный путь", count: lines.count))
    }

    func test_keepsTheValidPartOfAMixedList() {
        let result = CachePaths.normalizedSearchFolders(["~/Developer", "/", "relative", "/Volumes/Work/"], home: home)

        XCTAssertEqual(result.folders.map(\.path), ["/Users/tester/Developer", "/Volumes/Work"])
        XCTAssertEqual(result.rejected.map(\.line), ["/", "relative"])
        XCTAssertEqual(result.rejected.map(\.reason), ["это весь диск", "нужен полный путь"])
    }

    func test_emptyInputYieldsNoFolders() {
        let result = CachePaths.normalizedSearchFolders([], home: home)

        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_cachePathsDefaultsToNoFolders() {
        XCTAssertEqual(CachePaths(home: home).projectSearchFolders, [])
    }

    func test_cachePathsStandardizesFolders() {
        let paths = CachePaths(home: home, projectSearchFolders: [URL(fileURLWithPath: "/Volumes/Work/./x/..")])

        XCTAssertEqual(paths.projectSearchFolders.map(\.path), ["/Volumes/Work"])
    }
}
