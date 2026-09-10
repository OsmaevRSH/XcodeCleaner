import XCTest
@testable import XcodeCleanerCore

final class CleanupModelTests: XCTestCase {
    func test_cachePathsAreRootedInHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let paths = CachePaths(home: home)

        XCTAssertEqual(paths.xcodeCaches.map(\.path), [
            "/Users/tester/Library/Developer/Xcode/DerivedData",
            "/Users/tester/Library/Caches/com.apple.dt.Xcode",
        ])
        XCTAssertEqual(paths.previews.map(\.path), [
            "/Users/tester/Library/Developer/Xcode/UserData/Previews",
            "/Users/tester/Library/Developer/Xcode/DocumentationCache",
        ])
        XCTAssertEqual(paths.deviceSupport.count, 4)
        XCTAssertEqual(paths.archivesDirectory.path, "/Users/tester/Library/Developer/Xcode/Archives")
        XCTAssertEqual(paths.toolchainsDirectory.path, "/Users/tester/Library/Developer/Toolchains")
        XCTAssertEqual(paths.globalProjectCaches.map(\.path), ["/Users/tester/.cache/tuist"])
        XCTAssertEqual(paths.allClearable.count, 2 + 2 + 4 + 4 + 1)
        XCTAssertTrue(paths.previews.allSatisfy { paths.allClearable.contains($0) })
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
        XCTAssertNil(items[0].sizeBytes)
    }

    func test_simulatorModeDestructiveness() {
        XCTAssertFalse(SimulatorMode.deleteUnavailable.isDestructive)
        XCTAssertTrue(SimulatorMode.eraseAll.isDestructive)
        XCTAssertTrue(SimulatorMode.deleteAll.isDestructive)
        XCTAssertTrue(SimulatorMode.deleteAllAndRuntimes.isDestructive)
    }

    func test_kindsHaveExecutionOrder() {
        XCTAssertEqual(CleanupKind.executionOrder, [
            .xcodeCaches, .previews, .deviceSupport, .simulatorCaches, .simulators,
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

    func test_everyKindExplainsItselfInPlainWords() {
        for kind in CleanupKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) has no title")
            XCTAssertFalse(kind.subtitle.isEmpty, "\(kind) has no subtitle")
        }
        XCTAssertEqual(CleanupKind.xcodeCaches.title, "Кэши сборки")
        XCTAssertEqual(CleanupKind.previews.title, "Превью и документация")
    }

    func test_onlyThreeKindsDoNotComeBackOnTheirOwn() {
        let attention = CleanupKind.allCases.filter { $0.group == .attention }

        XCTAssertEqual(Set(attention), [.archives, .xcodeApps, .toolchains])
        XCTAssertEqual(attention.count, 3)
        XCTAssertEqual(CleanupKind.simulators.group, .safe)
    }

    func test_groupsAreTitledForHumans() {
        XCTAssertEqual(CleanupGroup.allCases, [.safe, .attention])
        XCTAssertEqual(CleanupGroup.safe.title, "Восстановится само")
        XCTAssertEqual(CleanupGroup.attention.title, "Не восстановится автоматически")
        XCTAssertEqual(CleanupGroup.safe.id, "safe")
    }

    func test_cacheItemBuilderReportsSymlinkedDirectories() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let real = try temp.makeDirectory("real/DerivedData")
        let directLink = try temp.makeSymlink("DerivedDataLink", to: real)
        _ = try temp.makeSymlink("linkdir", to: temp.url.appendingPathComponent("real"))
        let throughLink = temp.url.appendingPathComponent("linkdir/DerivedData")
        let missing = temp.url.appendingPathComponent("Missing")

        let skipped = CacheItemBuilder.symlinkedDirectories([real, directLink, throughLink, missing])

        XCTAssertEqual(skipped.map(\.path), [directLink.path, throughLink.path])
    }
}
