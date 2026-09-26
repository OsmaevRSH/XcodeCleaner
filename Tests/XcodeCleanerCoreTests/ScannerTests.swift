import XCTest
@testable import XcodeCleanerCore

final class ScannerTests: XCTestCase {
    private struct Fixture {
        let temp: TemporaryDirectory
        let scanner: XcodeCleanerCore.Scanner
        let derivedData: URL
        let archive: URL
        let xcode: URL
        let toolchain: URL
        let symlinkedToolchain: URL
        let mainStore: URL
        let otherStore: URL
        let mainMountPath: String
        let otherMountPath: String
    }

    /// A home with one of everything the scan can find, plus a fake `arc`/`xcode-select`/`simctl`.
    private func makeFixture() throws -> Fixture {
        let temp = try TemporaryDirectory()
        let derivedData = try temp.makeDirectory("Library/Developer/Xcode/DerivedData")
        try temp.makeFile("Library/Developer/Xcode/DerivedData/App-abc/Build/binary", bytes: 8192)
        try temp.makeFile("Library/Developer/Xcode/DerivedData/App-abc/Index/db", bytes: 4096)

        let archive = try temp.makeDirectory("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive")
        try temp.makeFile("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 2048)

        let applications = try temp.makeDirectory("Applications")
        let xcode = try temp.makeDirectory("Applications/Xcode-16.4.app")
        try temp.makeFile("Applications/Xcode-16.4.app/Contents/MacOS/Xcode", bytes: 16384)

        let toolchain = try temp.makeDirectory("Library/Developer/Toolchains/swift-5.9-RELEASE.xctoolchain")
        try temp.makeFile("Library/Developer/Toolchains/swift-5.9-RELEASE.xctoolchain/usr/bin/swift", bytes: 4096)
        let symlinkedToolchain = try temp.makeSymlink(
            "Library/Developer/Toolchains/swift-latest.xctoolchain",
            to: toolchain
        )

        let mainMount = try temp.makeDirectory("arcadia")
        let otherMount = try temp.makeDirectory("arcadia_TASK-1")
        let mainStore = try temp.makeDirectory("main-store")
        try temp.makeFile("main-store/objects/pack", bytes: 65536)
        let otherStore = try temp.makeDirectory(".arc/stores/_arcadia_TASK-1")
        try temp.makeFile(".arc/stores/_arcadia_TASK-1/objects/pack", bytes: 32768)

        let mountsJSON = """
        [
          {"status":"mounted","mount":"\(mainMount.path)","store":"\(mainStore.path)","object-store":"\(mainStore.path)/.arc/objects"},
          {"status":"unmounted","mount":"\(otherMount.path)","store":"\(otherStore.path)","object-store":"\(otherStore.path)/.arc/objects"}
        ]
        """

        let runner = FakeCommandRunner()
        runner.respond(to: "arc mount --list --json", stdout: mountsJSON)
        runner.respond(to: "xcode-select -p", stdout: "/none\n")
        runner.respond(to: "xcrun simctl list devices -j", stdout: #"{"devices":{}}"#)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: "{}")

        return Fixture(
            temp: temp,
            scanner: XcodeCleanerCore.Scanner(
                runner: runner,
                cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications)
            ),
            derivedData: derivedData,
            archive: archive,
            xcode: xcode,
            toolchain: toolchain,
            symlinkedToolchain: symlinkedToolchain,
            mainStore: mainStore,
            otherStore: otherStore,
            mainMountPath: mainMount.path,
            otherMountPath: otherMount.path
        )
    }

    /// Every size the scan cannot get for free stays nil, which is the structural form of "no tree
    /// was walked" — a wall-clock bound would only say the machine happened to be fast.
    func test_scanLeavesEverySizeUnknown() async throws {
        let fixture = try makeFixture()
        defer { fixture.temp.remove() }

        let result = await fixture.scanner.scan()

        XCTAssertTrue(result.cacheItems.contains { $0.id == fixture.derivedData.path })
        XCTAssertTrue(result.cacheItems.allSatisfy { $0.sizeBytes == nil })
        XCTAssertTrue(result.projectCacheItems.allSatisfy { $0.sizeBytes == nil })
        XCTAssertEqual(result.archives.map(\.sizeBytes), [nil])
        XCTAssertEqual(result.xcodes.map(\.sizeBytes), [nil])
        let realToolchain = try XCTUnwrap(result.toolchains.first { $0.url.path == fixture.toolchain.path })
        XCTAssertNil(realToolchain.sizeBytes)
        XCTAssertTrue(result.mounts.allSatisfy { $0.storeSizeBytes == nil })
    }

    func test_symlinkedToolchainNeedsNoMeasurement() async throws {
        let fixture = try makeFixture()
        defer { fixture.temp.remove() }

        let result = await fixture.scanner.scan()

        let symlinked = try XCTUnwrap(result.toolchains.first { $0.url.path == fixture.symlinkedToolchain.path })
        XCTAssertEqual(symlinked.sizeBytes, 0)
    }

    func test_measureSizesReportsTheSizesTheScanSkipped() async throws {
        let fixture = try makeFixture()
        defer { fixture.temp.remove() }
        let result = await fixture.scanner.scan()
        let collector = SizeCollector()

        await fixture.scanner.measureSizes(for: result) { collector.record($0, $1) }

        XCTAssertEqual(collector[fixture.derivedData.path], DirectorySizer.size(of: fixture.derivedData))
        XCTAssertGreaterThanOrEqual(collector[fixture.derivedData.path] ?? 0, 12288)
        XCTAssertEqual(collector[fixture.archive.path], DirectorySizer.size(of: fixture.archive))
        XCTAssertEqual(collector[fixture.xcode.path], DirectorySizer.size(of: fixture.xcode))
        XCTAssertEqual(collector[fixture.toolchain.path], DirectorySizer.size(of: fixture.toolchain))
        XCTAssertNil(collector[fixture.symlinkedToolchain.path])
        // Refilling the bounded group must not hand the same target out twice.
        XCTAssertEqual(collector.reportedIDs.count, collector.callCount)
    }

    func test_measureSizesReportsNonMainArcadiaStoresOnly() async throws {
        let fixture = try makeFixture()
        defer { fixture.temp.remove() }
        let result = await fixture.scanner.scan()
        let collector = SizeCollector()

        await fixture.scanner.measureSizes(for: result) { collector.record($0, $1) }

        XCTAssertEqual(collector[fixture.otherMountPath], DirectorySizer.size(of: fixture.otherStore))
        XCTAssertGreaterThanOrEqual(collector[fixture.otherMountPath] ?? 0, 32768)
        XCTAssertNil(collector[fixture.mainMountPath])
    }

    /// The property the whole naming change is for: whatever a category expands into, no two of its
    /// rows may read the same. Two mounted mounts each contribute the same three project caches, and
    /// two of the simulator caches are both CoreSimulator's.
    func test_noTwoItemsOfAKindShareATitle() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let clearable = CachePaths(home: temp.url).allClearable
        for path in clearable {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let mounts = ["arcadia", "arcadia_TASK-1"].map { temp.url.appendingPathComponent($0) }
        let subpaths = CachePaths(home: temp.url).projectCacheSubpaths
        for mount in mounts {
            for subpath in subpaths {
                try temp.makeDirectory("\(mount.lastPathComponent)/\(subpath)")
            }
        }
        let mountsJSON = mounts
            .map { #"{"status":"mounted","mount":"\#($0.path)","store":"\#($0.path)/store","object-store":"\#($0.path)/o"}"# }
            .joined(separator: ",")
        let runner = FakeCommandRunner()
        runner.respond(to: "arc mount --list --json", stdout: "[\(mountsJSON)]")
        runner.respond(to: "xcode-select -p", stdout: "/none\n")
        runner.respond(to: "xcrun simctl list devices -j", stdout: #"{"devices":{}}"#)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: "{}")
        let scanner = XcodeCleanerCore.Scanner(
            runner: runner,
            cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications)
        )

        let result = await scanner.scan()

        let items = result.cacheItems + result.projectCacheItems
        XCTAssertEqual(items.count, clearable.count + 2 * subpaths.count)
        for (kind, ofKind) in Dictionary(grouping: items, by: \.kind) {
            XCTAssertEqual(
                Set(ofKind.map(\.title)).count,
                ofKind.count,
                "\(kind) shows the same title twice: \(ofKind.map(\.title))"
            )
            XCTAssertTrue(ofKind.allSatisfy { $0.title.isEmpty == false }, "\(kind) has a nameless row")
        }
    }

    /// The second phase: `scan()` offers the fixed paths, and the walk that follows adds every
    /// `.build` somebody left behind with `swift build`. The fixed rows must not be reported twice.
    func test_discoverProjectCachesAddsTheBuildDirectoriesScanCannotKnowAbout() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let mount = try temp.makeDirectory("arcadia")
        try temp.makeDirectory("arcadia/mobile/saft/ios/Derived")
        for package in ["arcadia/mobile/saft/ios/Tools/SaftCITool", "arcadia/mobile/music/ios/modules/Maple"] {
            try temp.makeFile("\(package)/Package.swift", bytes: 10)
            try temp.makeFile("\(package)/.build/x", bytes: 10)
        }
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc mount --list --json",
            stdout: #"[{"status":"mounted","mount":"\#(mount.path)","store":"\#(mount.path)/s","object-store":"\#(mount.path)/o"}]"#
        )
        runner.respond(to: "xcode-select -p", stdout: "/none\n")
        runner.respond(to: "xcrun simctl list devices -j", stdout: #"{"devices":{}}"#)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: "{}")
        let scanner = XcodeCleanerCore.Scanner(
            runner: runner,
            cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications)
        )
        let result = await scanner.scan()
        let collector = ItemCollector()

        await scanner.discoverProjectCaches(for: result) { collector.record($0) }

        XCTAssertEqual(collector.items.map(\.id), [
            mount.appendingPathComponent("mobile/music/ios/modules/Maple/.build").path,
            mount.appendingPathComponent("mobile/saft/ios/Tools/SaftCITool/.build").path,
        ])
        XCTAssertTrue(collector.items.allSatisfy { $0.kind == .projectCaches && $0.sizeBytes == nil })
        XCTAssertEqual(collector.items.map(\.title), [
            "arcadia · mobile/music/ios/modules/Maple/.build",
            "arcadia · mobile/saft/ios/Tools/SaftCITool/.build",
        ])
        XCTAssertFalse(collector.items.contains { result.projectCacheItems.map(\.id).contains($0.id) })
    }

    /// A cache found in the background is deletable: the allowlist is derived from the items the
    /// result carries, so appending to it is all the discovery has to do.
    func test_makeDeleterAllowsADiscoveredBuildDirectory() {
        let paths = CachePaths(home: URL(fileURLWithPath: "/Users/tester"))
        let scanner = XcodeCleanerCore.Scanner(runner: FakeCommandRunner(), cachePaths: paths)
        let discovered = URL(fileURLWithPath: "/Users/tester/arcadia/mobile/saft/ios/Tools/SaftCITool/.build")
        var result = ScanResult()
        result.projectCacheItems = [
            CleanupItem(
                id: discovered.path,
                kind: .projectCaches,
                title: "arcadia · mobile/saft/ios/Tools/SaftCITool/.build",
                subtitle: discovered.path,
                action: .clearContents(discovered),
                sizeBytes: nil,
                isDestructive: false
            ),
        ]

        let deleter = scanner.makeDeleter(for: result)

        XCTAssertTrue(deleter.clearableDirectories.contains(discovered.path))
        XCTAssertTrue(deleter.clearableDirectories.contains(paths.xcodeCaches[0].url.path))
    }

    /// A runner on a machine without Arcadia: `arc` is not there, and nothing else is needed.
    private func runnerWithoutArc() -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc mount --list --json", stderr: "arc: command not found", exitCode: 127)
        runner.respond(to: "xcode-select -p", stdout: "/none\n")
        runner.respond(to: "xcrun simctl list devices -j", stdout: #"{"devices":{}}"#)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: "{}")
        return runner
    }

    /// This is what makes the app useful on a machine without Arcadia: the folders are walked on
    /// their own, with no mount in the result and `arc` failing outright.
    func test_discoverProjectCachesSearchesFoldersWithoutAnyMount() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let developer = try temp.makeDirectory("Developer")
        try temp.makeFile("Developer/MyLib/Package.swift", bytes: 10)
        try temp.makeFile("Developer/MyLib/.build/x", bytes: 10)
        let scanner = XcodeCleanerCore.Scanner(
            runner: runnerWithoutArc(),
            cachePaths: CachePaths(
                home: temp.url,
                applicationsDirectory: applications,
                projectSearchFolders: [developer]
            )
        )
        let result = await scanner.scan()
        let collector = ItemCollector()

        await scanner.discoverProjectCaches(for: result) { collector.record($0) }

        XCTAssertEqual(result.mounts, [])
        XCTAssertEqual(collector.items.map(\.id), [developer.appendingPathComponent("MyLib/.build").path])
        XCTAssertEqual(collector.items.map(\.title), ["~/Developer/MyLib/.build"])
        XCTAssertEqual(collector.items.map(\.subtitle), [developer.appendingPathComponent("MyLib/.build").path])
        XCTAssertTrue(collector.items.allSatisfy { $0.kind == .projectCaches && $0.sizeBytes == nil })
    }

    /// A folder that reaches a `.build` a mount root already reported does not report it again.
    func test_discoverProjectCachesReportsACacheReachableTwiceOnce() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let mount = try temp.makeDirectory("arcadia")
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/Package.swift", bytes: 10)
        try temp.makeFile("arcadia/mobile/saft/ios/Tools/.build/x", bytes: 10)
        let runner = runnerWithoutArc()
        runner.respond(
            to: "arc mount --list --json",
            stdout: #"[{"status":"mounted","mount":"\#(mount.path)","store":"\#(mount.path)/s","object-store":"\#(mount.path)/o"}]"#
        )
        let scanner = XcodeCleanerCore.Scanner(
            runner: runner,
            cachePaths: CachePaths(
                home: temp.url,
                applicationsDirectory: applications,
                projectSearchFolders: [mount.appendingPathComponent("mobile")]
            )
        )
        let result = await scanner.scan()
        let collector = ItemCollector()

        await scanner.discoverProjectCaches(for: result) { collector.record($0) }

        XCTAssertEqual(collector.items.map(\.title), ["arcadia · mobile/saft/ios/Tools/.build"])
    }

    /// The folder stays in the settings — it may be on a drive that is not plugged in — but the
    /// scan says it was skipped instead of silently finding nothing there.
    func test_scanWarnsAboutAFolderThatDoesNotExist() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let missing = temp.url.appendingPathComponent("Unplugged/Projects")
        let scanner = XcodeCleanerCore.Scanner(
            runner: runnerWithoutArc(),
            cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications, projectSearchFolders: [missing])
        )

        let result = await scanner.scan()

        XCTAssertTrue(result.warnings.contains("Папка для поиска не найдена, пропущена: ~/Unplugged/Projects"))
    }

    func test_scanWarnsAboutAFolderReachedThroughASymlink() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let real = try temp.makeDirectory("real")
        let link = try temp.makeSymlink("link", to: real)
        let scanner = XcodeCleanerCore.Scanner(
            runner: runnerWithoutArc(),
            cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications, projectSearchFolders: [link])
        )

        let result = await scanner.scan()

        XCTAssertTrue(result.warnings.contains("Пропущено, путь проходит через симлинк: \(link.path)"))
    }

    /// The walk that ran out of time says so in the log, and says which folder to narrow down.
    func test_discoverProjectCachesForwardsTheTimeBudgetWarning() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let developer = try temp.makeDirectory("Developer")
        let scanner = XcodeCleanerCore.Scanner(
            runner: runnerWithoutArc(),
            cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications, projectSearchFolders: [developer]),
            discoveryTimeBudget: .zero
        )
        let result = await scanner.scan()
        let warnings = LineCollector()

        await scanner.discoverProjectCaches(for: result, onDiscover: { _ in }, onWarning: { warnings.append($0) })

        XCTAssertEqual(warnings.lines, ["Поиск в ~/Developer остановлен через 0 с — укажите папку точнее"])
    }

    /// The deleter's allowlist is derived from the items the result carries, so a cache found in a
    /// folder is deletable the moment it is appended — exactly like one found in a mount.
    func test_makeDeleterAllowsABuildDirectoryDiscoveredInAFolder() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let applications = try temp.makeDirectory("Applications")
        let developer = try temp.makeDirectory("Developer")
        try temp.makeFile("Developer/MyLib/Package.swift", bytes: 10)
        try temp.makeFile("Developer/MyLib/.build/x", bytes: 10)
        let scanner = XcodeCleanerCore.Scanner(
            runner: runnerWithoutArc(),
            cachePaths: CachePaths(home: temp.url, applicationsDirectory: applications, projectSearchFolders: [developer])
        )
        var result = await scanner.scan()
        let collector = ItemCollector()
        await scanner.discoverProjectCaches(for: result) { collector.record($0) }
        let build = developer.appendingPathComponent("MyLib/.build")
        XCTAssertFalse(scanner.makeDeleter(for: result).clearableDirectories.contains(build.path))

        result.projectCacheItems += collector.items
        let deleter = scanner.makeDeleter(for: result)

        XCTAssertTrue(deleter.clearableDirectories.contains(build.path))
        XCTAssertEqual(try deleter.clearContents(of: build), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: build.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: developer.appendingPathComponent("MyLib/Package.swift").path))
    }

    func test_cancelledMeasureSizesReturnsWithoutReportingEverything() async throws {
        let fixture = try makeFixture()
        defer { fixture.temp.remove() }
        let result = await fixture.scanner.scan()
        let collector = SizeCollector()
        let finished = expectation(description: "measureSizes returned")

        let task = Task {
            await fixture.scanner.measureSizes(for: result) { collector.record($0, $1) }
            finished.fulfill()
        }
        task.cancel()

        await fulfillment(of: [finished], timeout: 5)
        let measurable = result.cacheItems.count + result.projectCacheItems.count
            + result.archives.count + result.xcodes.count + 1 + 1
        XCTAssertGreaterThan(measurable, 0)
        XCTAssertLessThan(collector.reportedIDs.count, measurable)
        XCTAssertEqual(collector.reportedIDs.count, collector.callCount)
    }
}
