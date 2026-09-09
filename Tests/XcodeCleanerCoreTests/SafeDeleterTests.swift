import XCTest
@testable import XcodeCleanerCore

final class SafeDeleterTests: XCTestCase {
    func test_clearContentsRemovesChildrenButKeepsDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/a.bin", bytes: 10)
        try temp.makeFile("DerivedData/sub/b.bin", bytes: 10)
        try temp.makeFile("DerivedData/.hidden", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])

        let failures = try deleter.clearContents(of: cache)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func test_clearContentsRejectsPathOutsideAllowlist() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let allowed = try temp.makeDirectory("allowed")
        let other = try temp.makeDirectory("other")
        try temp.makeFile("other/keep.bin", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [allowed], trashableParents: [])

        XCTAssertThrowsError(try deleter.clearContents(of: other)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .notAllowed(other.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("keep.bin").path))
    }

    func test_clearContentsRefusesSymlinkedDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let real = try temp.makeDirectory("real")
        try temp.makeFile("real/keep.bin", bytes: 10)
        let link = try temp.makeSymlink("link", to: real)
        let deleter = SafeDeleter(clearableDirectories: [link], trashableParents: [])

        XCTAssertThrowsError(try deleter.clearContents(of: link)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .isSymlink(link.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("keep.bin").path))
    }

    func test_clearContentsRemovesSymlinkChildWithoutFollowing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("cache")
        let outside = try temp.makeDirectory("outside")
        try temp.makeFile("outside/keep.bin", bytes: 10)
        _ = try temp.makeSymlink("cache/link", to: outside)
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])

        let failures = try deleter.clearContents(of: cache)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func test_trashRejectsItemOutsideTrashableParents() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let stray = try temp.makeFile("stray.bin", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        XCTAssertThrowsError(try deleter.trash(stray)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .notAllowed(stray.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func test_trashMovesDirectChildOfTrashableParent() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let item = try temp.makeFile("Archives/old.xcarchive", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        try deleter.trash(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }
}
