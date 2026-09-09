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

    func test_clearContentsRefusesDirectoryBehindSymlinkedAncestor() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let real = try temp.makeDirectory("real/DerivedData")
        try temp.makeFile("real/DerivedData/keep.bin", bytes: 10)
        _ = try temp.makeSymlink("linkdir", to: temp.url.appendingPathComponent("real"))
        let throughLink = temp.url.appendingPathComponent("linkdir/DerivedData")
        let deleter = SafeDeleter(clearableDirectories: [throughLink], trashableParents: [])

        XCTAssertThrowsError(try deleter.clearContents(of: throughLink)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .isSymlink(throughLink.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("keep.bin").path))
    }

    func test_clearContentsAcceptsUnnormalizedPathForAllowedDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/a.bin", bytes: 10)
        let unnormalized = temp.url.appendingPathComponent("other/../DerivedData")
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])

        let failures = try deleter.clearContents(of: unnormalized)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func test_trashRefusesDisallowedExtension() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let stray = try temp.makeFile("Archives/stray.bin", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        XCTAssertThrowsError(try deleter.trash(stray)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .notAllowed(stray.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func test_trashRefusesItemBehindSymlinkedAncestor() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeDirectory("real/Archives")
        let item = try temp.makeFile("real/Archives/old.xcarchive", bytes: 10)
        _ = try temp.makeSymlink("linkdir", to: temp.url.appendingPathComponent("real"))
        let parentThroughLink = temp.url.appendingPathComponent("linkdir/Archives")
        let itemThroughLink = parentThroughLink.appendingPathComponent("old.xcarchive")
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parentThroughLink])

        XCTAssertThrowsError(try deleter.trash(itemThroughLink)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .isSymlink(itemThroughLink.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func test_errorsHaveReadableDescriptions() {
        let errors: [SafeDeleterError] = [
            .notAllowed("/a"),
            .notADirectory("/b"),
            .isSymlink("/c"),
            .cannotInspect("/d", "boom"),
        ]
        for error in errors {
            XCTAssertEqual(error.localizedDescription, error.errorDescription)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(SafeDeleterError.notAllowed("/a").localizedDescription.contains("/a"))
        XCTAssertTrue(SafeDeleterError.cannotInspect("/d", "boom").localizedDescription.contains("boom"))
    }

    func test_cannotInspectCarriesUnderlyingReason() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])
        try FileManager.default.removeItem(at: cache)

        XCTAssertThrowsError(try deleter.clearContents(of: cache)) { error in
            guard case .cannotInspect(let path, let reason)? = error as? SafeDeleterError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(path, cache.path)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_trashRefusesMissingLeafBehindSymlinkedParent() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let realParent = try temp.makeDirectory("real/Archives")
        try temp.makeFile("real/Archives/keep.bin", bytes: 10)
        _ = try temp.makeSymlink("linkdir", to: temp.url.appendingPathComponent("real"))
        let parentThroughLink = temp.url.appendingPathComponent("linkdir/Archives")
        let missingThroughLink = parentThroughLink.appendingPathComponent("x.xcarchive")
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parentThroughLink])

        XCTAssertThrowsError(try deleter.trash(missingThroughLink)) { error in
            switch error as? SafeDeleterError {
            case .isSymlink, .notAllowed:
                break
            default:
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: realParent.appendingPathComponent("keep.bin").path))
    }

    func test_trashRefusesSymlinkedLeaf() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let real = try temp.makeFile("Archives/real.xcarchive", bytes: 10)
        let link = try temp.makeSymlink("Archives/link.xcarchive", to: real)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        XCTAssertThrowsError(try deleter.trash(link)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .isSymlink(link.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func test_trashAcceptsUppercaseExtension() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let item = try temp.makeFile("Archives/Old.XCARCHIVE", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        try deleter.trash(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }

    func test_trashRefusesMissingLeaf() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let missing = parent.appendingPathComponent("gone.xcarchive")
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        XCTAssertThrowsError(try deleter.trash(missing)) { error in
            guard case .cannotInspect? = error as? SafeDeleterError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }
}
