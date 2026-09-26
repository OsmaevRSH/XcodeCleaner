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

    /// A package somebody ran `swift build` in: the manifest and the cache it left next to it.
    private func makePackage(_ temp: TemporaryDirectory, _ directory: String) throws {
        try temp.makeFile("\(directory)/Package.swift", bytes: 10)
        try temp.makeFile("\(directory)/.build/x", bytes: 10)
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
        .directories
        .map(\.url.path)
    }

    private func discoveredPaths(folders: [URL], home: URL) -> [String] {
        ProjectCacheScanner.discoverBuildDirectories(inFolders: folders, home: home)
            .directories
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
        try makePackage(temp, "arcadia/mobile/saft/ios/Tuist")
        try makePackage(temp, "arcadia/mobile/saft/ios/MiniApps/Music/Sources/Modules/Core/MusicKitSaft")
        try makePackage(temp, "arcadia/mobile/music/ios/modules/Shared")
        try makePackage(temp, "arcadia/mobile/other/ios")
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

    /// In an arbitrary folder a `.build` may belong to anything, and the cleanup empties it. Only a
    /// manifest next to it says SwiftPM put it there.
    func test_mountWalkIgnoresBuildDirectoryWithoutSiblingManifest() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/mobile/saft/ios/Orphan/.build/x", bytes: 10)
        try temp.makeFile("arcadia/mobile/saft/ios/Nested/Package.swift", bytes: 10)
        try temp.makeFile("arcadia/mobile/saft/ios/Nested/Sub/.build/x", bytes: 10)
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path])
    }

    func test_folderWalkIgnoresBuildDirectoryWithoutSiblingManifest() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Developer")
        try temp.makeFile("Developer/web/.build/x", bytes: 10)
        try makePackage(temp, "Developer/MyLib")

        let found = discoveredPaths(folders: [folder], home: temp.url)

        XCTAssertEqual(found, [folder.appendingPathComponent("MyLib/.build").path])
    }

    /// «A regular file named `Package.swift`»: a directory of that name is not a manifest, and a
    /// symlink named so may point at a manifest of some other package entirely.
    func test_manifestMustBeARegularFile() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Developer")
        try temp.makeDirectory("Developer/A/Package.swift")
        try temp.makeFile("Developer/A/.build/x", bytes: 10)
        let elsewhere = try temp.makeFile("elsewhere/Package.swift", bytes: 10)
        try temp.makeFile("Developer/B/.build/x", bytes: 10)
        _ = try temp.makeSymlink("Developer/B/Package.swift", to: elsewhere)

        XCTAssertEqual(discoveredPaths(folders: [folder], home: temp.url), [])
    }

    /// SwiftPM checks packages out inside `.build`, and those have `.build` directories of their
    /// own. Descending would report caches the outer one already contains.
    func test_doesNotDescendIntoADiscoveredBuildDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools/.build/checkouts/Dep")
        let paths = CachePaths(home: temp.url)

        let found = discoveredPaths(mounts: [mount(mounted, status: .mounted)], cachePaths: paths)

        XCTAssertEqual(found, [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path])
    }

    func test_discoveryStopsAtMaxDepth() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try makePackage(temp, "arcadia/mobile/saft/ios/a")
        try makePackage(temp, "arcadia/mobile/saft/ios/a/b")
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
            try makePackage(temp, "arcadia/mobile/saft/ios/\(name)")
        }
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")
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
        try makePackage(temp, "outside/Package")
        let outsideBuild = outside.appendingPathComponent(".build")
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/Package.swift", bytes: 10)
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
        try makePackage(temp, "arcadia_B/mobile/saft/ios/Tools")
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
            try makePackage(temp, "\(name)/mobile/saft/ios/Tools/SaftCITool")
        }
        let paths = CachePaths(home: temp.url)
        let mounts = [
            mount(first, status: .mounted, isMain: true),
            mount(second, status: .mounted),
        ]

        let found = ProjectCacheScanner.discoverBuildDirectories(mounts: mounts, cachePaths: paths).directories
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
        try makePackage(temp, "arcadia/tools/cli/Sources")
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")
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
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")
        let paths = CachePaths(home: temp.url)

        let discovery = ProjectCacheScanner.discoverBuildDirectories(
            mounts: [mount(mounted, status: .mounted)],
            cachePaths: paths
        )

        XCTAssertEqual(
            discovery.directories.map(\.url.path),
            [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path]
        )
        XCTAssertEqual(discovery.warnings, [])
    }

    // MARK: Filesystem boundary

    /// A walk started at `~` must stay out of Arcadia's FUSE mounts, network volumes and external
    /// drives. Temporary directories all share one device, so the lookup is what gets faked.
    func test_folderWalkDoesNotDescendIntoAnotherDevice() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("home")
        try makePackage(temp, "home/Developer/MyLib")
        try makePackage(temp, "home/arcadia/mobile/saft/ios/Tools")
        try temp.makeFile("home/Other/Package.swift", bytes: 10)
        try temp.makeFile("home/Other/.build/x", bytes: 10)
        let foreign = [
            folder.appendingPathComponent("arcadia").path,
            folder.appendingPathComponent("Other/.build").path,
        ]
        let deviceID: (URL) -> Int? = { url in
            foreign.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } ? 2 : 1
        }

        let found = ProjectCacheScanner.discoverBuildDirectories(
            inFolders: [folder],
            home: temp.url,
            deviceID: deviceID
        )

        XCTAssertEqual(
            found.directories.map(\.url.path),
            [folder.appendingPathComponent("Developer/MyLib/.build").path]
        )
    }

    func test_mountWalkDoesNotDescendIntoAnotherDevice() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")
        try makePackage(temp, "arcadia/mobile/saft/ios/nested-volume/Pkg")
        let foreign = mounted.appendingPathComponent("mobile/saft/ios/nested-volume").path
        let deviceID: (URL) -> Int? = { url in
            url.path == foreign || url.path.hasPrefix(foreign + "/") ? 2 : 1
        }

        let found = ProjectCacheScanner.discoverBuildDirectories(
            mounts: [mount(mounted, status: .mounted)],
            cachePaths: CachePaths(home: temp.url),
            deviceID: deviceID
        )

        XCTAssertEqual(
            found.directories.map(\.url.path),
            [mounted.appendingPathComponent("mobile/saft/ios/Tools/.build").path]
        )
    }

    /// The boundary is the root's own device, not the home's: a folder on an external drive is
    /// walked in full, and only the walk that would cross into it from outside is stopped.
    func test_boundaryIsRelativeToTheRoot() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("disk")
        let external = try temp.makeDirectory("disk/External")
        try makePackage(temp, "disk/External/Projects/Lib")
        let deviceID: (URL) -> Int? = { url in
            url.path == external.path || url.path.hasPrefix(external.path + "/") ? 7 : 1
        }

        let fromParent = ProjectCacheScanner.discoverBuildDirectories(
            inFolders: [parent],
            home: temp.url,
            deviceID: deviceID
        )
        let fromExternal = ProjectCacheScanner.discoverBuildDirectories(
            inFolders: [external],
            home: temp.url,
            deviceID: deviceID
        )

        XCTAssertEqual(fromParent.directories, [])
        XCTAssertEqual(
            fromExternal.directories.map(\.url.path),
            [external.appendingPathComponent("Projects/Lib/.build").path]
        )
    }

    /// No device, no walk: a root that cannot even be stat-ed is not somewhere to look.
    func test_rootWithoutADeviceIsNotWalked() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Developer")
        try makePackage(temp, "Developer/MyLib")

        let found = ProjectCacheScanner.discoverBuildDirectories(
            inFolders: [folder],
            home: temp.url,
            deviceID: { _ in nil }
        )

        XCTAssertEqual(found.directories, [])
    }

    func test_realDeviceLookupReadsTheItemItself() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let file = try temp.makeFile("a/b", bytes: 1)

        XCTAssertNotNil(ProjectCacheScanner.deviceID(of: temp.url))
        XCTAssertEqual(ProjectCacheScanner.deviceID(of: file), ProjectCacheScanner.deviceID(of: temp.url))
        XCTAssertNil(ProjectCacheScanner.deviceID(of: temp.url.appendingPathComponent("missing")))
    }

    // MARK: Folders

    func test_folderDiscoveryFindsPackagesAndTitlesThemFromHome() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Developer")
        try makePackage(temp, "Developer/MyLib")
        try makePackage(temp, "Developer/apps/Tool/Sources/Pkg")

        let found = ProjectCacheScanner.discoverBuildDirectories(inFolders: [folder], home: temp.url)

        XCTAssertEqual(found.directories.map(\.title), [
            "~/Developer/MyLib/.build",
            "~/Developer/apps/Tool/Sources/Pkg/.build",
        ].sorted())
        XCTAssertEqual(found.directories.map(\.url.path), [
            folder.appendingPathComponent("MyLib/.build").path,
            folder.appendingPathComponent("apps/Tool/Sources/Pkg/.build").path,
        ].sorted())
        XCTAssertEqual(found.warnings, [])
    }

    func test_folderOutsideHomeKeepsItsFullPathAsTitle() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let home = try temp.makeDirectory("Users/tester")
        let folder = try temp.makeDirectory("Volumes/Work")
        try makePackage(temp, "Volumes/Work/Lib")

        let found = ProjectCacheScanner.discoverBuildDirectories(inFolders: [folder], home: home)

        XCTAssertEqual(found.directories.map(\.title), [folder.appendingPathComponent("Lib/.build").path])
    }

    func test_displayPathAbbreviatesTheHomeDirectoryOnly() {
        let home = URL(fileURLWithPath: "/Users/tester")

        XCTAssertEqual(CachePaths.displayPath(URL(fileURLWithPath: "/Users/tester"), home: home), "~")
        XCTAssertEqual(
            CachePaths.displayPath(URL(fileURLWithPath: "/Users/tester/Developer/MyLib/.build"), home: home),
            "~/Developer/MyLib/.build"
        )
        XCTAssertEqual(
            CachePaths.displayPath(URL(fileURLWithPath: "/Users/tester2/Developer"), home: home),
            "/Users/tester2/Developer"
        )
        XCTAssertEqual(CachePaths.displayPath(URL(fileURLWithPath: "/opt/src"), home: home), "/opt/src")
        XCTAssertEqual(
            CachePaths(home: home).displayPath(URL(fileURLWithPath: "/Users/tester/x")),
            "~/x"
        )
    }

    /// Walking them is slow — `~/Library` alone holds hundreds of thousands of directories — and
    /// neither ever holds a project. Only the ones directly under the home are meant.
    func test_folderWalkSkipsLibraryAndTrashDirectlyUnderHome() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try makePackage(temp, "Library/Developer/Pkg")
        try makePackage(temp, ".Trash/Old")
        try makePackage(temp, "Developer/MyLib")
        try makePackage(temp, "Developer/Library/Pkg")
        try makePackage(temp, "Developer/.Trash/Pkg")

        let found = discoveredPaths(folders: [temp.url], home: temp.url)

        XCTAssertEqual(found, [
            temp.url.appendingPathComponent("Developer/.Trash/Pkg/.build").path,
            temp.url.appendingPathComponent("Developer/Library/Pkg/.build").path,
            temp.url.appendingPathComponent("Developer/MyLib/.build").path,
        ])
    }

    func test_folderWalkAppliesTheSkipListAndDepthBound() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Developer")
        try makePackage(temp, "Developer/web/node_modules/pkg")
        try makePackage(temp, "Developer/App.xcodeproj/inner")
        try makePackage(temp, "Developer/1/2/3/4/5/6/7")
        try makePackage(temp, "Developer/1/2/3/4/5/6/7/8")

        let found = discoveredPaths(folders: [folder], home: temp.url)

        XCTAssertEqual(found, [folder.appendingPathComponent("1/2/3/4/5/6/7/.build").path])
    }

    /// `~` and `~/Developer` both reach the same package; it is one cache and one row.
    func test_nestedFoldersReportACacheOnce() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let folder = try temp.makeDirectory("Developer")
        try makePackage(temp, "Developer/MyLib")

        let found = discoveredPaths(folders: [temp.url, folder], home: temp.url)

        XCTAssertEqual(found, [folder.appendingPathComponent("MyLib/.build").path])
    }

    func test_missingFolderYieldsNothing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let found = ProjectCacheScanner.discoverBuildDirectories(
            inFolders: [temp.url.appendingPathComponent("gone")],
            home: temp.url
        )

        XCTAssertEqual(found.directories, [])
        XCTAssertEqual(found.warnings, [])
    }

    /// Every `.build` found goes through the deleter's allowlist as a string, and a path spelled
    /// through a symlink never matches it. So a folder reached through one is not walked at all.
    func test_folderBehindASymlinkIsNotWalked() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let real = try temp.makeDirectory("real")
        try makePackage(temp, "real/MyLib")
        let link = try temp.makeSymlink("link", to: real)

        XCTAssertEqual(discoveredPaths(folders: [link], home: temp.url), [])
    }

    // MARK: Time budget

    /// A clock that moves one second every time it is read, so a budget of a few seconds runs out
    /// after a few directories without the test sleeping through any of them.
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now

        func now() -> ContinuousClock.Instant {
            lock.withLock {
                current += .seconds(1)
                return current
            }
        }
    }

    func test_rootThatRunsOutOfTimeStopsAndTheNextOneStillRuns() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let huge = try temp.makeDirectory("huge")
        for index in 0..<20 {
            try makePackage(temp, "huge/dir\(index)/pkg")
        }
        let small = try temp.makeDirectory("small")
        try makePackage(temp, "small/Lib")
        let clock = SteppingClock()

        let found = ProjectCacheScanner.discoverBuildDirectories(
            inFolders: [huge, small],
            home: temp.url,
            timeBudget: .seconds(5),
            now: clock.now
        )

        let fromHuge = found.directories.filter { $0.url.path.hasPrefix(huge.path + "/") }
        XCTAssertLessThan(fromHuge.count, 20)
        XCTAssertTrue(found.directories.contains { $0.url.path == small.appendingPathComponent("Lib/.build").path })
        XCTAssertEqual(found.warnings, [
            "Поиск в ~/huge остановлен через 5 с — укажите папку точнее",
        ])
    }

    func test_mountRootThatRunsOutOfTimeIsReported() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia")
        try makePackage(temp, "arcadia/mobile/saft/ios/Tools")

        let found = ProjectCacheScanner.discoverBuildDirectories(
            mounts: [mount(mounted, status: .mounted)],
            cachePaths: CachePaths(home: temp.url, projectSearchRoots: ["mobile/saft/ios"]),
            timeBudget: .zero
        )

        XCTAssertEqual(found.directories, [])
        XCTAssertEqual(found.warnings, [
            "Поиск в ~/arcadia/mobile/saft/ios остановлен через 0 с — укажите папку точнее",
        ])
    }

    func test_defaultBudgetIsThirtySeconds() {
        XCTAssertEqual(ProjectCacheScanner.defaultTimeBudget, .seconds(30))
        XCTAssertEqual(ProjectCacheScanner.defaultMaxDepth, 8)
    }
}
