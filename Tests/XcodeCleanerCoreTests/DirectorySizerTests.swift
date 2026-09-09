import XCTest
@testable import XcodeCleanerCore

final class DirectorySizerTests: XCTestCase {
    func test_sumsRegularFilesRecursively() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeFile("a.bin", bytes: 10_000)
        try temp.makeFile("nested/b.bin", bytes: 20_000)

        let size = DirectorySizer.size(of: temp.url)

        XCTAssertGreaterThanOrEqual(size, 30_000)
        XCTAssertLessThan(size, 30_000 + 2 * 4096)
    }

    func test_doesNotFollowSymlinks() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let outside = try TemporaryDirectory()
        defer { outside.remove() }
        let big = try outside.makeFile("big.bin", bytes: 500_000)
        try temp.makeFile("small.bin", bytes: 1_000)
        _ = try temp.makeSymlink("link.bin", to: big)

        let size = DirectorySizer.size(of: temp.url)

        XCTAssertLessThan(size, 100_000)
    }

    func test_missingPathIsZero() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertEqual(DirectorySizer.size(of: missing), 0)
    }
}
