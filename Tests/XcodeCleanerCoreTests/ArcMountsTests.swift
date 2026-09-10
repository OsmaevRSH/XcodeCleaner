import XCTest
@testable import XcodeCleanerCore

final class ArcMountsTests: XCTestCase {
    private let listJSON = """
    [
      {"status":"mounted","mount":"/Users/tester/arcadia","store":"/Users/tester/store","object-store":"/Users/tester/store/.arc/objects"},
      {"status":"unmounted","mount":"/Users/tester/arcadia_SAFTIOS-1","store":"/Users/tester/.arc/stores/_Users_tester_arcadia_SAFTIOS-1","object-store":"/Users/tester/store/.arc/objects"},
      {"status":"mounted","mount":"/Users/tester/arcadia_SAFTIOS-2","store":"/Users/tester/.arc/stores/_Users_tester_arcadia_SAFTIOS-2","object-store":"/Users/tester/.arc/stores/_Users_tester_arcadia_SAFTIOS-2/.arc/objects"}
    ]
    """

    private func makeManager(_ runner: FakeCommandRunner, home: URL) -> ArcMountManager {
        runner.respond(to: "arc mount --list --json", stdout: listJSON)
        return ArcMountManager(runner: runner, home: home)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func test_parsesList() throws {
        let mounts = try ArcMount.parse(Data(listJSON.utf8))

        XCTAssertEqual(mounts.count, 3)
        XCTAssertEqual(mounts[0].status, .mounted)
        XCTAssertEqual(mounts[1].status, .unmounted)
        XCTAssertEqual(mounts[1].objectStore, "/Users/tester/store/.arc/objects")
        XCTAssertEqual(mounts[1].name, "arcadia_SAFTIOS-1")
    }

    func test_listMarksMainAndSharedObjectStore() async throws {
        let runner = FakeCommandRunner()
        let manager = makeManager(runner, home: URL(fileURLWithPath: "/Users/tester"))

        let infos = try await manager.list()

        XCTAssertEqual(infos.map(\.mount.mount), [
            "/Users/tester/arcadia",
            "/Users/tester/arcadia_SAFTIOS-1",
            "/Users/tester/arcadia_SAFTIOS-2",
        ])
        XCTAssertTrue(infos[0].isMain)
        XCTAssertTrue(infos.allSatisfy { $0.storeSizeBytes == nil })
        XCTAssertTrue(infos[1].sharesMainObjectStore)
        XCTAssertFalse(infos[2].sharesMainObjectStore)
        XCTAssertEqual(runner.calls[0].currentDirectory, "/Users/tester")
    }

    func test_unmountWithAndWithoutForce() async throws {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        try await manager.unmount("/Users/tester/arcadia_SAFTIOS-2", force: false) { _ in }
        try await manager.unmount("/Users/tester/arcadia_SAFTIOS-2", force: true) { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc unmount /Users/tester/arcadia_SAFTIOS-2",
            "arc unmount --force /Users/tester/arcadia_SAFTIOS-2",
        ])
    }

    func test_unmountFailurePropagatesStderr() async {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc unmount /Users/tester/arcadia_SAFTIOS-2", stderr: "busy", exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        do {
            try await manager.unmount("/Users/tester/arcadia_SAFTIOS-2", force: false) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", "busy"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_removeUnmountsIfMountedThenForgetsAndRemovesEmptyDir() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-2")
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: "/s", objectStore: "/o")

        try await manager.remove(mount) { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc unmount \(mountDir.path)",
            "arc unmount --forget \(mountDir.path)",
        ])
        XCTAssertFalse(exists(mountDir))
    }

    func test_removeSkipsUnmountForAnUnmountedMount() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-4")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-4")
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        try await manager.remove(mount) { _ in }

        XCTAssertEqual(runner.callLines, ["arc unmount --forget \(mountDir.path)"])
        XCTAssertFalse(exists(store))
        XCTAssertFalse(exists(mountDir))
    }

    func test_removeContinuesWhenArcReportsAlreadyUnmounted() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-5")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-5")
        try temp.makeFile(".arc/stores/_arcadia_SAFTIOS-5/blob.bin", bytes: 4096)
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount \(mountDir.path)",
            stderr: "Repository seems to be already unmounted",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: store.path, objectStore: "/o")
        let logged = LineCollector()

        try await manager.remove(mount) { logged.append($0) }

        XCTAssertEqual(runner.callLines, [
            "arc unmount \(mountDir.path)",
            "arc unmount --forget \(mountDir.path)",
        ])
        XCTAssertFalse(exists(store))
        XCTAssertFalse(exists(mountDir))
        XCTAssertTrue(logged.contains("уже размонтирован"))
    }

    func test_removeThrowsWhenUnmountFailsForAnotherReason() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-3")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-3")
        let runner = FakeCommandRunner()
        runner.respond(to: "arc unmount \(mountDir.path)", stderr: "busy", exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        do {
            try await manager.remove(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", "busy"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(runner.callLines, ["arc unmount \(mountDir.path)"])
        XCTAssertTrue(exists(mountDir))
        XCTAssertTrue(exists(store))
    }

    func test_removeDeletesStoreItselfWhenForgetFails() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-6")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-6")
        try temp.makeFile(".arc/stores/_arcadia_SAFTIOS-6/blob.bin", bytes: 4096)
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount --forget \(mountDir.path)",
            stdout: "Not an arc repository. Are you sure that you are unmounting correct path: '\(mountDir.path)' ?",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")
        let logged = LineCollector()

        try await manager.remove(mount) { logged.append($0) }

        XCTAssertFalse(exists(store))
        XCTAssertFalse(exists(mountDir))
        XCTAssertTrue(logged.contains("Not an arc repository."))
        XCTAssertTrue(logged.contains(store.path))
    }

    func test_removeThrowsWhenForgetFailsAndStoreIsMissing() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-7")
        let store = temp.url.appendingPathComponent(".arc/stores/_arcadia_SAFTIOS-7")
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount --forget \(mountDir.path)",
            stdout: "Not an arc repository.",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        do {
            try await manager.remove(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount --forget", "Not an arc repository."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_removeRefusesStoreOutsideArcStores() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let outside = try TemporaryDirectory()
        defer { outside.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-8")
        let store = try outside.makeDirectory("evil")
        try outside.makeFile("evil/precious.bin", bytes: 512)
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount --forget \(mountDir.path)",
            stdout: "Not an arc repository.",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")
        let logged = LineCollector()

        do {
            try await manager.remove(mount) { logged.append($0) }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .refusedPath(store.path))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(exists(store))
        XCTAssertTrue(exists(store.appendingPathComponent("precious.bin")))
        XCTAssertTrue(exists(mountDir))
        XCTAssertTrue(logged.contains("Not an arc repository."))
    }

    func test_removeKeepsNonEmptyDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-1")
        try temp.makeFile("arcadia_SAFTIOS-1/leftover", bytes: 1)
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: "/s", objectStore: "/o")
        let logged = LineCollector()

        try await manager.remove(mount) { logged.append($0) }

        XCTAssertEqual(runner.callLines, ["arc unmount --forget \(mountDir.path)"])
        XCTAssertTrue(exists(mountDir))
        XCTAssertTrue(logged.contains("не пуста"))
    }

    func test_removeRefusesMainMount() async {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
        let main = ArcMount(status: .mounted, mount: "/Users/tester/arcadia", store: "/s", objectStore: "/o")

        do {
            try await manager.remove(main) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .mainMountProtected)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(runner.callLines.isEmpty)
    }

    func test_comparablePathNormalizesSpellingRelativeToInjectedHome() {
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(manager.comparablePath("/Users/tester/arcadia/"), "/users/tester/arcadia")
        XCTAssertEqual(manager.comparablePath("/Users/tester/./arcadia"), "/users/tester/arcadia")
        XCTAssertEqual(manager.comparablePath("/Users/Tester/arcadia"), "/users/tester/arcadia")
        XCTAssertEqual(manager.comparablePath("~/arcadia"), "/users/tester/arcadia")
        XCTAssertEqual(manager.comparablePath("~"), "/users/tester")
        XCTAssertEqual(manager.comparablePath("/"), "/")
        XCTAssertEqual(manager.comparablePath("//"), "/")
    }

    func test_normalizedPathKeepsOriginalCaseAndDropsTrailingSlash() {
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(manager.normalizedPath("/Users/Tester/arcadia_X/"), "/Users/Tester/arcadia_X")
        XCTAssertEqual(manager.normalizedPath("~/arcadia_X"), "/Users/tester/arcadia_X")
    }

    func test_removeRefusesMainMountSpelledDifferently() async {
        let spellings = [
            "/Users/tester/arcadia/",
            "/Users/tester/./arcadia",
            "/Users/Tester/arcadia",
        ]
        for spelling in spellings {
            let runner = FakeCommandRunner()
            let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
            let mount = ArcMount(status: .mounted, mount: spelling, store: "/s", objectStore: "/o")

            do {
                try await manager.remove(mount) { _ in }
                XCTFail("expected throw for \(spelling)")
            } catch let error as ArcMountError {
                XCTAssertEqual(error, .mainMountProtected, "spelling \(spelling)")
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(runner.callLines.isEmpty, "spelling \(spelling)")
        }
    }

    func test_removeRefusesTildeSpelledMainMount() async {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
        let mount = ArcMount(status: .mounted, mount: "~/arcadia", store: "/s", objectStore: "/o")

        do {
            try await manager.remove(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .mainMountProtected)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(runner.callLines.isEmpty)
    }

    func test_removeRefusesPathsNotInsideHome() async {
        for path in ["/", "/Users", "/Users/tester", "/Users/other/arcadia_x"] {
            let runner = FakeCommandRunner()
            let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
            let mount = ArcMount(status: .mounted, mount: path, store: "/s", objectStore: "/o")

            do {
                try await manager.remove(mount) { _ in }
                XCTFail("expected throw for \(path)")
            } catch let error as ArcMountError {
                XCTAssertEqual(error, .refusedPath(path), "path \(path)")
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(runner.callLines.isEmpty, "path \(path)")
        }
    }

    func test_removeNormalizesTrailingSlashBeforePassingPathToArc() async throws {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
        let mount = ArcMount(status: .unmounted, mount: "/Users/tester/arcadia_X/", store: "/s", objectStore: "/o")

        try await manager.remove(mount) { _ in }

        XCTAssertEqual(runner.callLines, ["arc unmount --forget /Users/tester/arcadia_X"])
    }

    func test_unmountRefusesPathsNotInsideHome() async {
        for path in ["/", "/Users", "/Users/tester", "/Users/other/arcadia_x"] {
            let runner = FakeCommandRunner()
            let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

            do {
                try await manager.unmount(path, force: false) { _ in }
                XCTFail("expected throw for \(path)")
            } catch let error as ArcMountError {
                XCTAssertEqual(error, .refusedPath(path), "path \(path)")
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(runner.callLines.isEmpty, "path \(path)")
        }
    }

    func test_listMarksMainMountSpelledWithTrailingSlash() async throws {
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [{"status":"mounted","mount":"/Users/tester/arcadia/","store":"/Users/tester/store","object-store":"/o"}]
            """
        )
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        let infos = try await manager.list()

        XCTAssertEqual(infos.count, 1)
        XCTAssertTrue(infos[0].isMain)
        XCTAssertNil(infos[0].storeSizeBytes)
    }

    func test_mountsSortsMainFirstThenNaturally() async throws {
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [
              {"status":"mounted","mount":"/Users/tester/arcadia_SAFTIOS-10","store":"/s","object-store":"/o"},
              {"status":"mounted","mount":"/Users/tester/arcadia","store":"/s","object-store":"/o"},
              {"status":"mounted","mount":"/Users/tester/arcadia_SAFTIOS-2","store":"/s","object-store":"/o"}
            ]
            """
        )
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        let mounts = try await manager.mounts()

        XCTAssertEqual(mounts.map(\.name), [
            "arcadia",
            "arcadia_SAFTIOS-2",
            "arcadia_SAFTIOS-10",
        ])
    }

    func test_mountsThrowsWhenCommandFails() async {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc mount --list --json", stderr: "no arc", exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        do {
            _ = try await manager.mounts()
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc mount --list", "no arc"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_mountsThrowsOnMalformedJSON() async {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc mount --list --json", stdout: "{not json")
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        do {
            _ = try await manager.mounts()
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            guard case .commandFailed(let command, let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(command, "arc mount --list")
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_storeSizesSkipMainMountAndSumStores() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory("store-a")
        try temp.makeFile("store-a/blob.bin", bytes: 4096)
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: temp.url)
        let main = ArcMount(
            status: .mounted,
            mount: temp.url.appendingPathComponent("arcadia").path,
            store: store.path,
            objectStore: "/o"
        )
        let other = ArcMount(
            status: .mounted,
            mount: temp.url.appendingPathComponent("arcadia_SAFTIOS-1").path,
            store: store.path,
            objectStore: "/o"
        )

        let sizes = await manager.storeSizes(for: [main, other])

        XCTAssertNil(sizes[main.mount])
        XCTAssertGreaterThanOrEqual(sizes[other.mount] ?? 0, 4096)
    }

    func test_storeSizeMeasuresOneStoreAndSkipsMainMount() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory("store-a")
        try temp.makeFile("store-a/blob.bin", bytes: 4096)
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: temp.url)
        let main = ArcMount(
            status: .mounted,
            mount: temp.url.appendingPathComponent("arcadia").path,
            store: store.path,
            objectStore: "/o"
        )
        let other = ArcMount(
            status: .mounted,
            mount: temp.url.appendingPathComponent("arcadia_SAFTIOS-1").path,
            store: store.path,
            objectStore: "/o"
        )

        XCTAssertNil(manager.storeSize(for: main))
        XCTAssertGreaterThanOrEqual(manager.storeSize(for: other) ?? 0, 4096)
    }

    func test_listDoesNotMeasureStoreSizes() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        let otherMount = temp.url.appendingPathComponent("arcadia_SAFTIOS-1").path
        let store = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-1")
        try temp.makeFile(".arc/stores/_arcadia_SAFTIOS-1/blob.bin", bytes: 4096)
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [
              {"status":"mounted","mount":"\(mainMount)","store":"/store","object-store":"/o"},
              {"status":"mounted","mount":"\(otherMount)","store":"\(store.path)","object-store":"/o"}
            ]
            """
        )
        let fileManager = RecordingFileManager()
        let manager = ArcMountManager(runner: runner, home: temp.url, fileManager: fileManager)

        let infos = try await manager.list()

        XCTAssertEqual(runner.callLines, ["arc mount --list --json"])
        XCTAssertTrue(infos.allSatisfy { $0.storeSizeBytes == nil })
        XCTAssertFalse(fileManager.inspectedPaths.contains(store.path))
    }

    func test_lastUsedPrefersArcMetadataDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory("store")
        let metadata = try temp.makeDirectory("store/.arc")
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: metadata.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: store.path
        )

        let date = ArcMountManager.lastUsed(ofStore: store.path, fileManager: .default)

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
    }

    func test_lastUsedFallsBackToStoreRootWhenMetadataIsMissing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory("store")
        let expected = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: store.path)

        let date = ArcMountManager.lastUsed(ofStore: store.path, fileManager: .default)

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
    }

    func test_lastUsedIsNilWhenStoreIsMissing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let date = ArcMountManager.lastUsed(
            ofStore: temp.url.appendingPathComponent("gone").path,
            fileManager: .default
        )

        XCTAssertNil(date)
    }

    func test_listReadsLastUsedFromStoreMetadata() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-1")
        let metadata = try temp.makeDirectory(".arc/stores/_arcadia_SAFTIOS-1/.arc")
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: metadata.path)
        let runner = FakeCommandRunner()
        let used = temp.url.appendingPathComponent("arcadia_SAFTIOS-1").path
        let missing = temp.url.appendingPathComponent("arcadia_SAFTIOS-2").path
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [
              {"status":"mounted","mount":"\(used)","store":"\(store.path)","object-store":"/o"},
              {"status":"mounted","mount":"\(missing)","store":"\(temp.url.appendingPathComponent("gone").path)","object-store":"/o"}
            ]
            """
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)

        let infos = try await manager.list()

        XCTAssertEqual(infos.count, 2)
        XCTAssertEqual(
            infos[0].lastUsedAt?.timeIntervalSince1970 ?? 0,
            expected.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertNil(infos[1].lastUsedAt)
    }
}

/// Records every `fileExists` probe so a test can prove that store directories were never
/// inspected (`DirectorySizer` starts with exactly this call).
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var inspectedPaths: [String] { lock.withLock { storage } }

    override func fileExists(atPath path: String) -> Bool {
        lock.withLock { storage.append(path) }
        return super.fileExists(atPath: path)
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        lock.withLock { storage.append(path) }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
}
