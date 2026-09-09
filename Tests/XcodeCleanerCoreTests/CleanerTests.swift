import XCTest
@testable import XcodeCleanerCore

final class CleanerTests: XCTestCase {
    private func idleRunner() -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 0, stdout: "", stderr: "")
        for name in RunningAppsCheck.watchedProcesses {
            runner.respond(to: "pgrep -x \(name)", exitCode: 1)
        }
        return runner
    }

    func test_orderedFollowsKindExecutionOrder() {
        let items = [
            CleanupItem(id: "p", kind: .projectCaches, title: "", subtitle: "", action: .clearContents(URL(fileURLWithPath: "/p")), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "a", kind: .archives, title: "", subtitle: "", action: .trash(URL(fileURLWithPath: "/a")), sizeBytes: nil, isDestructive: true),
            CleanupItem(id: "x", kind: .xcodeCaches, title: "", subtitle: "", action: .clearContents(URL(fileURLWithPath: "/x")), sizeBytes: nil, isDestructive: false),
        ]

        XCTAssertEqual(Cleaner.ordered(items).map(\.id), ["x", "a", "p"])
    }

    func test_refusesToRunWhenXcodeIsOpen() async throws {
        let runner = idleRunner()
        runner.respond(to: "pgrep -x Xcode", stdout: "1", exitCode: 0)
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)

        do {
            _ = try await cleaner.run([]) { _ in }
            XCTFail("expected throw")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .blockingProcesses(["Xcode"]))
        }
    }

    func test_runsItemsInOrderAndReportsResults() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/junk", bytes: 10)
        let archivesDir = try temp.makeDirectory("Archives")
        let archive = try temp.makeFile("Archives/Old.xcarchive", bytes: 10)
        let notAllowed = try temp.makeDirectory("NotAllowed")
        let runner = idleRunner()
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [archivesDir])
        let cleaner = Cleaner(runner: runner, deleter: deleter, home: temp.url)
        let items = [
            CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteAllAndRuntimes), sizeBytes: nil, isDestructive: true),
            CleanupItem(id: "cache", kind: .xcodeCaches, title: "", subtitle: "", action: .clearContents(cache), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "bad", kind: .projectCaches, title: "", subtitle: "", action: .clearContents(notAllowed), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "archive", kind: .archives, title: "", subtitle: "", action: .trash(archive), sizeBytes: nil, isDestructive: true),
        ]
        let logged = LineCollector()

        let report = try await cleaner.run(items) { logged.append($0) }

        XCTAssertEqual(report.results.map(\.itemID), ["cache", "sim", "archive", "bad"])
        XCTAssertEqual(report.results.map(\.succeeded), [true, true, true, false])
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertNotNil(report.diskBefore)
        XCTAssertNotNil(report.diskAfter)
        let trashedPath = try XCTUnwrap(
            report.results.first { $0.itemID == "archive" }?.message?.components(separatedBy: ": ").last
        )
        defer { try? FileManager.default.removeItem(atPath: trashedPath) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notAllowed.path))
        let simctlCalls = runner.callLines.filter { $0.hasPrefix("xcrun simctl") }
        XCTAssertEqual(simctlCalls, [
            "xcrun simctl shutdown all",
            "xcrun simctl delete unavailable",
            "xcrun simctl runtime dyld_shared_cache remove --all",
            "xcrun simctl delete all",
            "xcrun simctl runtime delete all",
        ])
        XCTAssertEqual(runner.callLines.last, "sync")
        XCTAssertTrue(logged.contains("NotAllowed"))
        XCTAssertTrue(logged.contains("в Корзину"))
    }

    func test_eraseAllModeUsesEraseCommand() async throws {
        let runner = idleRunner()
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)
        let item = CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.eraseAll), sizeBytes: nil, isDestructive: true)

        _ = try await cleaner.run([item]) { _ in }

        let simctlCalls = runner.callLines.filter { $0.hasPrefix("xcrun simctl") }
        XCTAssertEqual(simctlCalls, [
            "xcrun simctl shutdown all",
            "xcrun simctl delete unavailable",
            "xcrun simctl runtime dyld_shared_cache remove --all",
            "xcrun simctl erase all",
        ])
    }

    func test_simctlFailureMarksItemFailed() async throws {
        let runner = idleRunner()
        runner.respond(to: "xcrun simctl delete unavailable", stderr: "boom", exitCode: 1)
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)
        let item = CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteUnavailable), sizeBytes: nil, isDestructive: false)

        let report = try await cleaner.run([item]) { _ in }

        XCTAssertEqual(report.results[0].succeeded, false)
        XCTAssertEqual(report.results[0].message, "simctl delete unavailable: boom")
    }

    func test_clearContentsFailureMessageUsesDeleterDescription() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let notAllowed = try temp.makeDirectory("NotAllowed")
        let runner = idleRunner()
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: temp.url)
        let item = CleanupItem(id: "bad", kind: .projectCaches, title: "", subtitle: "", action: .clearContents(notAllowed), sizeBytes: nil, isDestructive: false)

        let report = try await cleaner.run([item]) { _ in }

        XCTAssertEqual(report.results[0].succeeded, false)
        XCTAssertEqual(
            report.results[0].message,
            SafeDeleterError.notAllowed(notAllowed.path).localizedDescription
        )
    }

    func test_simctlFailureWithoutStderrReportsExitCode() async throws {
        let runner = idleRunner()
        runner.respond(to: "xcrun simctl delete unavailable", exitCode: 1)
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)
        let item = CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteUnavailable), sizeBytes: nil, isDestructive: false)

        let report = try await cleaner.run([item]) { _ in }

        XCTAssertEqual(report.results[0].message, "simctl delete unavailable: exit 1")
    }

    func test_simctlKilledBySignalIsReportedAsSignal() async throws {
        let runner = idleRunner()
        runner.respond(to: "xcrun simctl delete unavailable", exitCode: 9, terminatedBySignal: true)
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)
        let item = CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteUnavailable), sizeBytes: nil, isDestructive: false)

        let report = try await cleaner.run([item]) { _ in }

        XCTAssertEqual(report.results[0].message, "simctl delete unavailable: killed by signal 9")
    }

    func test_cancelledRunStopsBeforeTouchingAnything() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        let junk = try temp.makeFile("DerivedData/junk", bytes: 10)
        let runner = idleRunner()
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])
        let cleaner = Cleaner(runner: runner, deleter: deleter, home: temp.url)
        let items = [
            CleanupItem(id: "cache", kind: .xcodeCaches, title: "", subtitle: "", action: .clearContents(cache), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteAll), sizeBytes: nil, isDestructive: true),
        ]
        let logged = LineCollector()

        let task = Task { try await cleaner.run(items) { logged.append($0) } }
        task.cancel()
        let report = try await task.value

        XCTAssertLessThan(report.results.count, items.count)
        XCTAssertFalse(runner.callLines.contains { $0.hasPrefix("xcrun simctl delete") })
        XCTAssertTrue(logged.contains("Прервано пользователем"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: junk.path))
    }

    func test_trashOfDisallowedParentIsRecordedAsFailureAndRunContinues() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/junk", bytes: 10)
        let stray = try temp.makeFile("Elsewhere/Stray.xcarchive", bytes: 10)
        let runner = idleRunner()
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])
        let cleaner = Cleaner(runner: runner, deleter: deleter, home: temp.url)
        let items = [
            CleanupItem(id: "stray", kind: .archives, title: "", subtitle: "", action: .trash(stray), sizeBytes: nil, isDestructive: true),
            CleanupItem(id: "cache", kind: .projectCaches, title: "", subtitle: "", action: .clearContents(cache), sizeBytes: nil, isDestructive: false),
        ]

        let report = try await cleaner.run(items) { _ in }

        XCTAssertEqual(report.results.map(\.itemID), ["stray", "cache"])
        XCTAssertEqual(report.results.map(\.succeeded), [false, true])
        XCTAssertEqual(
            report.results[0].message,
            SafeDeleterError.notAllowed(stray.path).localizedDescription
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func test_makeDeleterAllowsArchiveDayFoldersAndMountedProjectCaches() {
        let paths = CachePaths(home: URL(fileURLWithPath: "/Users/tester"))
        let scanner = Scanner(runner: FakeCommandRunner(), cachePaths: paths)
        var result = ScanResult()
        result.xcodes = [
            XcodeInstallation(
                url: paths.applicationsDirectory.appendingPathComponent("Xcode-16.0.app"),
                isActive: false,
                sizeBytes: 1
            ),
        ]
        result.toolchains = [
            ToolchainEntry(
                url: paths.toolchainsDirectory.appendingPathComponent("swift-6.0.xctoolchain"),
                isProtected: false,
                sizeBytes: 1
            ),
        ]
        result.archives = [
            ArchiveEntry(
                url: paths.archivesDirectory.appendingPathComponent("2026-09-09/App.xcarchive"),
                createdAt: Date(),
                sizeBytes: 1
            ),
            ArchiveEntry(
                url: paths.archivesDirectory.appendingPathComponent("2026-09-08/Other.xcarchive"),
                createdAt: Date(),
                sizeBytes: 2
            ),
        ]
        result.mounts = [
            ArcMountInfo(
                mount: ArcMount(
                    status: .mounted,
                    mount: "/Users/tester/arcadia",
                    store: "/Users/tester/.arc/stores/main",
                    objectStore: "/Users/tester/.arc/object-store"
                ),
                storeSizeBytes: nil,
                isMain: true,
                sharesMainObjectStore: true
            ),
            ArcMountInfo(
                mount: ArcMount(
                    status: .unmounted,
                    mount: "/Users/tester/arcadia_old",
                    store: "/Users/tester/.arc/stores/old",
                    objectStore: "/Users/tester/.arc/object-store"
                ),
                storeSizeBytes: 10,
                isMain: false,
                sharesMainObjectStore: true
            ),
        ]

        let deleter = scanner.makeDeleter(for: result)

        XCTAssertTrue(deleter.trashableParents.contains(paths.applicationsDirectory.path))
        XCTAssertTrue(deleter.trashableParents.contains(paths.toolchainsDirectory.path))
        XCTAssertTrue(deleter.trashableParents.contains(paths.archivesDirectory.appendingPathComponent("2026-09-09").path))
        XCTAssertTrue(deleter.trashableParents.contains(paths.archivesDirectory.appendingPathComponent("2026-09-08").path))
        XCTAssertFalse(deleter.trashableParents.contains(paths.archivesDirectory.path))

        for subpath in CachePaths.projectCacheSubpaths {
            XCTAssertTrue(deleter.clearableDirectories.contains("/Users/tester/arcadia/\(subpath)"))
        }
        XCTAssertFalse(deleter.clearableDirectories.contains { $0.hasPrefix("/Users/tester/arcadia_old") })
        XCTAssertTrue(deleter.clearableDirectories.contains("/Users/tester/.cache/tuist"))
        XCTAssertTrue(deleter.clearableDirectories.contains(paths.xcodeCaches[0].path))
    }

    func test_makeDeleterTrashesNothingWhenScanFoundNoTrashableEntries() {
        let paths = CachePaths(home: URL(fileURLWithPath: "/Users/tester"))
        let scanner = Scanner(runner: FakeCommandRunner(), cachePaths: paths)

        let deleter = scanner.makeDeleter(for: ScanResult())

        XCTAssertFalse(deleter.trashableParents.contains(paths.applicationsDirectory.path))
        XCTAssertFalse(deleter.trashableParents.contains(paths.toolchainsDirectory.path))
        XCTAssertTrue(deleter.trashableParents.isEmpty)
    }

    func test_scanBuildsResultFromExistingCachesOnly() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeDirectory("Library/Developer/Xcode/DerivedData")
        let applications = try temp.makeDirectory("Applications")
        let developer = try temp.makeDirectory("Applications/Xcode-1.0.app/Contents/Developer")
        let runner = FakeCommandRunner()
        runner.respond(to: "xcrun simctl list devices -j", stdout: #"{"devices":{}}"#)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: "{}")
        runner.respond(to: "xcode-select -p", stdout: "\(developer.path)\n")
        runner.respond(to: "arc mount --list --json", stdout: "[]")
        let paths = CachePaths(home: temp.url, applicationsDirectory: applications)
        let scanner = Scanner(runner: runner, cachePaths: paths)

        let result = await scanner.scan()

        XCTAssertEqual(result.xcodes.map(\.name), ["Xcode-1.0.app"])
        XCTAssertEqual(result.xcodes.map(\.isActive), [true])
        XCTAssertEqual(result.cacheItems.count, 1)
        XCTAssertEqual(result.cacheItems.first?.title, "DerivedData")
        XCTAssertEqual(result.cacheItems.first?.kind, .xcodeCaches)
        XCTAssertTrue(result.mounts.isEmpty)
        XCTAssertTrue(result.projectCacheItems.isEmpty)
        XCTAssertTrue(result.archives.isEmpty)
        XCTAssertTrue(result.toolchains.isEmpty)
        XCTAssertNotNil(result.disk)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.simulators, SimulatorInventory(devices: [], runtimes: []))
    }
}
