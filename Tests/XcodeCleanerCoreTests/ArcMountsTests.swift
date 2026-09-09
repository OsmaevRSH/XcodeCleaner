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
        XCTAssertNil(infos[0].storeSizeBytes)
        XCTAssertTrue(infos[1].sharesMainObjectStore)
        XCTAssertFalse(infos[2].sharesMainObjectStore)
        XCTAssertEqual(runner.calls[0].currentDirectory, "/Users/tester")
    }

    func test_mountPathValidation() throws {
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(try manager.mountPath(forName: "SAFTIOS-1").path, "/Users/tester/arcadia_SAFTIOS-1")
        XCTAssertThrowsError(try manager.mountPath(forName: ""))
        XCTAssertThrowsError(try manager.mountPath(forName: "a/b"))
        XCTAssertThrowsError(try manager.mountPath(forName: "a b"))
        XCTAssertThrowsError(try manager.mountPath(forName: ".."))
    }

    func test_mountNewRunsArcMountWithMainObjectStore() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [{"status":"mounted","mount":"\(mainMount)","store":"/store","object-store":"/store/.arc/objects"}]
            """
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)

        let path = try await manager.mountNew(name: "SAFTIOS-9") { _ in }

        XCTAssertEqual(path.path, temp.url.appendingPathComponent("arcadia_SAFTIOS-9").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(runner.callLines.last, "arc mount -m \(path.path) --object-store /store/.arc/objects --override-object-store")
    }

    func test_mountNewRefusesNonEmptyDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeFile("arcadia_busy/file", bytes: 1)
        let runner = FakeCommandRunner()
        let manager = makeManager(runner, home: temp.url)

        do {
            _ = try await manager.mountNew(name: "busy") { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .directoryNotEmpty(temp.url.appendingPathComponent("arcadia_busy").path))
        }
        XCTAssertFalse(runner.callLines.contains { $0.hasPrefix("arc mount -m") })
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

    func test_forgetUnmountsIfMountedThenForgetsAndRemovesEmptyDir() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-2")
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: "/s", objectStore: "/o")

        try await manager.forget(mount) { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc unmount \(mountDir.path)",
            "arc unmount --forget \(mountDir.path)",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountDir.path))
    }

    func test_forgetKeepsNonEmptyDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-1")
        try temp.makeFile("arcadia_SAFTIOS-1/leftover", bytes: 1)
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: "/s", objectStore: "/o")
        let logged = LineCollector()

        try await manager.forget(mount) { logged.append($0) }

        XCTAssertEqual(runner.callLines, ["arc unmount --forget \(mountDir.path)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountDir.path))
        XCTAssertTrue(logged.contains("не пуста"))
    }

    func test_forgetRefusesMainMount() async {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
        let main = ArcMount(status: .mounted, mount: "/Users/tester/arcadia", store: "/s", objectStore: "/o")

        do {
            try await manager.forget(main) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .mainMountProtected)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(runner.callLines.isEmpty)
    }

    func test_canonicalNormalizesSpelling() {
        XCTAssertEqual(ArcMountManager.canonical("/Users/tester/arcadia/"), "/users/tester/arcadia")
        XCTAssertEqual(ArcMountManager.canonical("/Users/tester/./arcadia"), "/users/tester/arcadia")
        XCTAssertEqual(ArcMountManager.canonical("/Users/Tester/arcadia"), "/users/tester/arcadia")
        XCTAssertEqual(ArcMountManager.canonical("/"), "/")
        XCTAssertEqual(ArcMountManager.canonical("//"), "/")
    }

    func test_forgetRefusesMainMountSpelledDifferently() async {
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
                try await manager.forget(mount) { _ in }
                XCTFail("expected throw for \(spelling)")
            } catch let error as ArcMountError {
                XCTAssertEqual(error, .mainMountProtected, "spelling \(spelling)")
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(runner.callLines.isEmpty, "spelling \(spelling)")
        }
    }

    func test_forgetRefusesTildeSpelledMainMount() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: home)
        let mount = ArcMount(status: .mounted, mount: "~/arcadia", store: "/s", objectStore: "/o")

        do {
            try await manager.forget(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .mainMountProtected)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(runner.callLines.isEmpty)
    }

    func test_forgetRefusesPathsNotInsideHome() async {
        for path in ["/", "/Users", "/Users/tester", "/Users/other/arcadia_x"] {
            let runner = FakeCommandRunner()
            let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
            let mount = ArcMount(status: .mounted, mount: path, store: "/s", objectStore: "/o")

            do {
                try await manager.forget(mount) { _ in }
                XCTFail("expected throw for \(path)")
            } catch let error as ArcMountError {
                XCTAssertEqual(error, .refusedPath(path), "path \(path)")
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(runner.callLines.isEmpty, "path \(path)")
        }
    }

    func test_forgetAbortsWhenUnmountFails() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-3")
        let runner = FakeCommandRunner()
        runner.respond(to: "arc unmount \(mountDir.path)", stderr: "busy", exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: "/s", objectStore: "/o")

        do {
            try await manager.forget(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", "busy"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(runner.callLines, ["arc unmount \(mountDir.path)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountDir.path))
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

    func test_mountNewDoesNotSizeStores() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        let storePath = temp.url.appendingPathComponent("missing-store").path
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [{"status":"mounted","mount":"\(mainMount)","store":"\(storePath)","object-store":"/store/.arc/objects"}]
            """
        )
        let fileManager = RecordingFileManager()
        let manager = ArcMountManager(runner: runner, home: temp.url, fileManager: fileManager)

        let path = try await manager.mountNew(name: "SAFTIOS-9") { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc mount --list --json",
            "arc mount -m \(path.path) --object-store /store/.arc/objects --override-object-store",
        ])
        XCTAssertFalse(fileManager.inspectedPaths.contains(storePath))
    }

    func test_mountNewRemovesDirectoryWhenArcMountFails() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [{"status":"mounted","mount":"\(mainMount)","store":"/store","object-store":"/store/.arc/objects"}]
            """
        )
        let newMount = temp.url.appendingPathComponent("arcadia_SAFTIOS-8").path
        runner.respond(
            to: "arc mount -m \(newMount) --object-store /store/.arc/objects --override-object-store",
            stderr: "boom",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let logged = LineCollector()

        do {
            _ = try await manager.mountNew(name: "SAFTIOS-8") { logged.append($0) }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc mount", "boom"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: newMount))
        XCTAssertTrue(logged.contains("rmdir \(newMount)"))
    }

    func test_mountNewPassesLeadingDashNameAsPathSuffix() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [{"status":"mounted","mount":"\(mainMount)","store":"/store","object-store":"/store/.arc/objects"}]
            """
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)

        let path = try await manager.mountNew(name: "-rf") { _ in }

        XCTAssertEqual(path.path, temp.url.appendingPathComponent("arcadia_-rf").path)
        XCTAssertEqual(
            runner.callLines.last,
            "arc mount -m \(temp.url.appendingPathComponent("arcadia_-rf").path) --object-store /store/.arc/objects --override-object-store"
        )
    }

    func test_mountPathRejectsControlCharacters() {
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertThrowsError(try manager.mountPath(forName: "SAFTIOS\u{0}-1"))
        XCTAssertThrowsError(try manager.mountPath(forName: "SAFTIOS\u{7}-1"))
        XCTAssertThrowsError(try manager.mountPath(forName: "SAFTIOS\u{1b}-1"))
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
