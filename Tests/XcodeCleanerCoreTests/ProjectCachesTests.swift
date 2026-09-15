import XCTest
@testable import XcodeCleanerCore

final class ProjectCachesTests: XCTestCase {
    private func mount(_ url: URL, status: ArcMount.Status, isMain: Bool = false) -> ArcMountInfo {
        ArcMountInfo(
            mount: ArcMount(status: status, mount: url.path, store: "/s", objectStore: "/o"),
            storeSizeBytes: nil,
            isMain: isMain,
            sharesMainObjectStore: true,
            lastUsedAt: nil
        )
    }

    private func discoveredPaths(
        mounts: [ArcMountInfo],
        cachePaths: CachePaths,
        maxDepth: Int = 8
    ) -> [String] {
        ProjectCacheScanner.discoverBuildDirectories(
            mounts: mounts,
            cachePaths: cachePaths,
            maxDepth: maxDepth
        )
        .map(\.url.path)
    }

    func test_collectsOnlyExistingSubpathsOfMountedMounts() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia_A")
        try temp.makeFile("arcadia_A/mobile/saft/ios/Derived/y", bytes: 10)
        try temp.makeFile("arcadia_A/mobile/music/ios/DerivedData/y", bytes: 10)
        let unmounted = try temp.makeDirectory("arcadia_B")
        try temp.makeFile("arcadia_B/mobile/saft/ios/Derived/z", bytes: 10)
        let global = try temp.makeDirectory(".cache/tuist")
        let paths = CachePaths(home: temp.url)
        let mounts = [
            mount(mounted, status: .mounted, isMain: true),
            mount(unmounted, status: .unmounted),
        ]

        let items = ProjectCacheScanner.items(mounts: mounts, cachePaths: paths)
        let allowlist = ProjectCacheScanner.allowedDirectories(mounts: mounts, cachePaths: paths)

        XCTAssertEqual(Set(items.map(\.id)), [
            global.path,
            mounted.appendingPathComponent("mobile/saft/ios/Derived").path,
            mounted.appendingPathComponent("mobile/music/ios/DerivedData").path,
        ])
        XCTAssertTrue(items.allSatisfy { $0.kind == .projectCaches })
        XCTAssertEqual(allowlist.count, 1 + 4)
        XCTAssertTrue(allowlist.contains(mounted.appendingPathComponent("mobile/saft/ios/DerivedData")))
    }

    /// The complaint this exists for: two mounts used to contribute the same fixed subpaths each,
    /// and every row read exactly like the row from the other mount.
    func test_projectCacheRowsNameTheirMount() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let first = try temp.makeDirectory("arcadia")
        let second = try temp.makeDirectory("arcadia_TASK-1")
        let paths = CachePaths(home: temp.url)
        for name in ["arcadia", "arcadia_TASK-1"] {
            for subpath in paths.projectCacheSubpaths {
                try temp.makeFile("\(name)/\(subpath)/x", bytes: 10)
            }
        }
        try temp.makeDirectory(".cache/tuist")
        let mounts = [
            mount(first, status: .mounted, isMain: true),
            mount(second, status: .mounted),
        ]

        let items = ProjectCacheScanner.items(mounts: mounts, cachePaths: paths)

        XCTAssertEqual(items.map(\.title), [
            "Общий кэш Tuist",
            "arcadia · mobile/saft/ios/Derived",
            "arcadia · mobile/saft/ios/DerivedData",
            "arcadia · mobile/music/ios/Derived",
            "arcadia · mobile/music/ios/DerivedData",
            "arcadia_TASK-1 · mobile/saft/ios/Derived",
            "arcadia_TASK-1 · mobile/saft/ios/DerivedData",
            "arcadia_TASK-1 · mobile/music/ios/Derived",
            "arcadia_TASK-1 · mobile/music/ios/DerivedData",
        ])
        XCTAssertEqual(Set(items.map(\.title)).count, items.count)
        XCTAssertEqual(
            items.first { $0.title == "arcadia_TASK-1 · mobile/saft/ios/Derived" }?.subtitle,
            second.appendingPathComponent("mobile/saft/ios/Derived").path
        )
    }

    /// The whole point of the walk: `swift build` leaves a `.build` next to every `Package.swift`,
    /// and no fixed list of paths can know where those packages are.
    func test_discoversBuildDirectoriesSeveralLevelsDown() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/mobile/saft/ios/Tuist/.build/x", bytes: 10)
        try temp.makeFile(
            "arcadia/mobile/saft/ios/MiniApps/Music/Sources/Modules/Core/MusicKitSaft/.build/x",
            bytes: 10
        )
        try temp.makeFile("arcadia/mobile/music/ios/modules/Shared/.build/x", bytes: 10)
        try temp.makeFile("arcadia/mobile/other/ios/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [
            mounted.appendingPathComponent("mobile/music/ios/modules/Shared/.build").path,
            mounted.appendingPathComponent(
                "mobile/saft/ios/MiniApps/Music/Sources/Modules/Core/MusicKitSaft/.build"
            ).path,
            mounted.appendingPathComponent("mobile/saft/ios/Tuist/.build").path,
        ])
    }

    /// SwiftPM checks packages out inside `.build`, and those have `.build` directories of their
    /// own. Descending would report caches the outer one already contains.
    func test_doesNotDescendIntoADiscoveredBuildDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/.build/checkouts/Dep/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path])
    }

    func test_discoveryStopsAtMaxDepth() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/mobile/saft/ios/a/.build/x", bytes: 10)
        try temp.makeFile("arcadia/mobile/saft/ios/a/b/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url)
        let mounts = [mount(mounted, status: .mounted)]

        XCTAssertEqual(discoveredPaths(mounts: mounts, cachePaths: paths, maxDepth: 2), [
            mounted.appendingPathComponent("mobile/saft/ios/a/.build").path,
        ])
        XCTAssertEqual(discoveredPaths(mounts: mounts, cachePaths: paths, maxDepth: 3), [
            mounted.appendingPathComponent("mobile/saft/ios/a/.build").path,
            mounted.appendingPathComponent("mobile/saft/ios/a/b/.build").path,
        ])
        XCTAssertEqual(discoveredPaths(mounts: mounts, cachePaths: paths, maxDepth: 1), [])
    }

    /// Both halves of the skip list: the named directories, and the bundles recognised by suffix.
    /// A `.build` inside any of them is either not a SwiftPM cache or is already covered by the
    /// fixed paths, and walking into `node_modules` is what would make the walk expensive.
    func test_discoverySkipsExcludedDirectoryNames() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        let excluded = [
            ".git", ".arc", ".swiftpm", ".overlay_v2", "node_modules", "DerivedData", "Derived",
            "xcuserdata", "Foo.xcodeproj", "Foo.xcworkspace", "Foo.framework", "Foo.app",
        ]
        for name in excluded {
            try temp.makeFile("arcadia/mobile/saft/ios/\(name)/.build/x", bytes: 10)
        }
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path])
    }

    /// A symlink leads out of the mount — and, when it points at an ancestor, in circles. Neither
    /// the `.build` behind a linked directory nor a `.build` that is itself a link belongs in the
    /// list: clearing the second one empties whatever it points at.
    func test_discoveryDoesNotFollowSymlinks() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        let outside = try temp.makeDirectory("outside/Package")
        let outsideBuild = try temp.makeDirectory("outside/Package/.build")
        try temp.makeFile("outside/Package/.build/x", bytes: 10)
        try temp.makeDirectory("arcadia/mobile/saft/ios/Tools")
        _ = try temp.makeSymlink("arcadia/mobile/saft/ios/linked", to: outside)
        _ = try temp.makeSymlink("arcadia/mobile/saft/ios/Tools/.build", to: outsideBuild)
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [])
    }

    /// An unmounted mount has nothing behind its directory to walk, and the bytes its `.build`
    /// directories will take once it is mounted again live in its store, which the Arcadia tab
    /// already measures and deletes.
    func test_discoverySkipsUnmountedMounts() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let unmounted = try temp.makeDirectory("arcadia_B")
        try temp.makeFile("arcadia_B/mobile/saft/ios/Tools/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(unmounted, status: .unmounted)], cachePaths: paths)

        XCTAssertEqual(found, [])
    }

    /// The same package is checked out in every mount, so the path alone names every row the same.
    func test_discoveredCachesNameTheirMountAndKeepTheirPath() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let first = try temp.makeDirectory("arcadia")
        let second = try temp.makeDirectory("arcadia_TASK-1")
        for name in ["arcadia", "arcadia_TASK-1"] {
            try temp.makeFile("\(name)/mobile/saft/ios/Tools/SaftCITool/.build/x", bytes: 10)
        }
        let paths = CachePaths(home: temp.url)
        let mounts = [
            mount(first, status: .mounted, isMain: true),
            mount(second, status: .mounted),
        ]

        let found = ProjectCacheScanner.discoverBuildDirectories(mounts: mounts, cachePaths: paths)
        let items = CacheItemBuilder.items(kind: .projectCaches, directories: found)

        XCTAssertEqual(found.map(\.title), [
            "arcadia · mobile/saft/ios/Tools/SaftCITool/.build",
            "arcadia_TASK-1 · mobile/saft/ios/Tools/SaftCITool/.build",
        ])
        XCTAssertEqual(Set(found.map(\.title)).count, found.count)
        XCTAssertEqual(items.map(\.subtitle), [
            first.appendingPathComponent("mobile/saft/ios/Tools/SaftCITool/.build").path,
            second.appendingPathComponent("mobile/saft/ios/Tools/SaftCITool/.build").path,
        ])
    }

    func test_discoveryHonoursCustomSearchRoots() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/tools/cli/Sources/.build/x", bytes: 10)
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url, projectSearchRoots: ["tools/cli"])

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [mounted.appendingPathComponent("tools/cli/Sources/.build").path])
    }

    /// A root that is not checked out in this mount is not an error: mounts hold different subsets
    /// of the monorepo, and the other root still has to be walked.
    func test_discoverySkipsMissingRootsSilently() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/.build/x", bytes: 10)
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path])
    }
}
