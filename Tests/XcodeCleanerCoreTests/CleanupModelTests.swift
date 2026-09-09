import XCTest
@testable import XcodeCleanerCore

final class CleanupModelTests: XCTestCase {
    func test_cachePathsAreRootedInHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let paths = CachePaths(home: home)

        XCTAssertEqual(paths.xcodeCaches.map(\.path), [
            "/Users/tester/Library/Developer/Xcode/DerivedData",
            "/Users/tester/Library/Developer/Xcode/DocumentationCache",
            "/Users/tester/Library/Developer/Xcode/UserData/Previews",
            "/Users/tester/Library/Caches/com.apple.dt.Xcode",
        ])
        XCTAssertEqual(paths.deviceSupport.count, 4)
        XCTAssertEqual(paths.archivesDirectory.path, "/Users/tester/Library/Developer/Xcode/Archives")
        XCTAssertEqual(paths.toolchainsDirectory.path, "/Users/tester/Library/Developer/Toolchains")
        XCTAssertEqual(paths.globalProjectCaches.map(\.path), ["/Users/tester/.cache/tuist"])
        XCTAssertEqual(paths.allClearable.count, 4 + 4 + 4 + 1)
    }

    func test_cacheItemBuilderSkipsMissingDirectories() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let existing = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/x.bin", bytes: 4096)
        let missing = temp.url.appendingPathComponent("Missing")

        let items = CacheItemBuilder.items(kind: .xcodeCaches, directories: [existing, missing])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, existing.path)
        XCTAssertEqual(items[0].kind, .xcodeCaches)
        XCTAssertEqual(items[0].action, .clearContents(existing))
        XCTAssertFalse(items[0].isDestructive)
        XCTAssertGreaterThanOrEqual(items[0].sizeBytes ?? 0, 4096)
    }

    func test_simulatorModeDestructiveness() {
        XCTAssertFalse(SimulatorMode.deleteUnavailable.isDestructive)
        XCTAssertTrue(SimulatorMode.eraseAll.isDestructive)
        XCTAssertTrue(SimulatorMode.deleteAll.isDestructive)
        XCTAssertTrue(SimulatorMode.deleteAllAndRuntimes.isDestructive)
    }

    func test_kindsHaveExecutionOrder() {
        XCTAssertEqual(CleanupKind.executionOrder, [
            .xcodeCaches, .deviceSupport, .simulatorCaches, .simulators,
            .archives, .xcodeApps, .toolchains, .projectCaches,
        ])
    }

    func test_cacheItemBuilderSkipsSymlinkedDirectories() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let real = try temp.makeDirectory("real/DerivedData")
        try temp.makeFile("real/DerivedData/x.bin", bytes: 4096)
        let directLink = try temp.makeSymlink("DerivedDataLink", to: real)
        _ = try temp.makeSymlink("linkdir", to: temp.url.appendingPathComponent("real"))
        let throughLink = temp.url.appendingPathComponent("linkdir/DerivedData")

        let items = CacheItemBuilder.items(
            kind: .xcodeCaches,
            directories: [real, directLink, throughLink]
        )

        XCTAssertEqual(items.map(\.id), [real.path])
    }

    func test_executionOrderCoversAllKinds() {
        XCTAssertEqual(Set(CleanupKind.executionOrder), Set(CleanupKind.allCases))
        XCTAssertEqual(CleanupKind.executionOrder.count, CleanupKind.allCases.count)
    }
}
