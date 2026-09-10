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
