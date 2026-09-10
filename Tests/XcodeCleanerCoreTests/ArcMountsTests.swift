import XCTest
@testable import XcodeCleanerCore

final class ArcMountsTests: XCTestCase {
    private let listJSON = """
    [
      {"status":"mounted","mount":"/Users/tester/arcadia","store":"/Users/tester/store","object-store":"/Users/tester/store/.arc/objects"},
      {"status":"unmounted","mount":"/Users/tester/arcadia_TASK-1","store":"/Users/tester/.arc/stores/_Users_tester_arcadia_TASK-1","object-store":"/Users/tester/store/.arc/objects"},
      {"status":"mounted","mount":"/Users/tester/arcadia_TASK-2","store":"/Users/tester/.arc/stores/_Users_tester_arcadia_TASK-2","object-store":"/Users/tester/.arc/stores/_Users_tester_arcadia_TASK-2/.arc/objects"}
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
        XCTAssertEqual(mounts[1].name, "arcadia_TASK-1")
    }

    func test_listMarksMainAndSharedObjectStore() async throws {
        let runner = FakeCommandRunner()
        let manager = makeManager(runner, home: URL(fileURLWithPath: "/Users/tester"))

        let infos = try await manager.list()

        XCTAssertEqual(infos.map(\.mount.mount), [
            "/Users/tester/arcadia",
            "/Users/tester/arcadia_TASK-1",
            "/Users/tester/arcadia_TASK-2",
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

        try await manager.unmount("/Users/tester/arcadia_TASK-2", force: false) { _ in }
        try await manager.unmount("/Users/tester/arcadia_TASK-2", force: true) { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc unmount /Users/tester/arcadia_TASK-2",
            "arc unmount --force /Users/tester/arcadia_TASK-2",
        ])
    }

    func test_unmountFailurePropagatesStderr() async {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc unmount /Users/tester/arcadia_TASK-2", stderr: "busy", exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        do {
            try await manager.unmount("/Users/tester/arcadia_TASK-2", force: false) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", "busy"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_unmountFailureReportsDiagnosticsWrittenToStdout() async {
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount /Users/tester/arcadia_TASK-2",
            stdout: "Not an arc repository.",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        do {
            try await manager.unmount("/Users/tester/arcadia_TASK-2", force: false) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", "Not an arc repository."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_removeUnmountsIfMountedThenForgetsAndRemovesEmptyDir() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-2")
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
        let mountDir = try temp.makeDirectory("arcadia_TASK-4")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-4")
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
        let mountDir = try temp.makeDirectory("arcadia_TASK-5")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-5")
        try temp.makeFile(".arc/stores/_arcadia_TASK-5/blob.bin", bytes: 4096)
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

    /// `arc` writes `[DEBUG]` traces to stderr and hints to stdout, so a failure that merely
    /// mentions the words "already unmounted" is not the sentence that means the mount is gone.
    /// Swallowing it would let a live, busy mount reach the store deletion below.
    func test_removeThrowsWhenOutputOnlyHintsAtAlreadyUnmounted() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-9")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-9")
        try temp.makeFile(".arc/stores/_arcadia_TASK-9/blob.bin", bytes: 4096)
        let hint = "error: mount is busy; if the repository is already unmounted, use --forget"
        let runner = FakeCommandRunner()
        runner.respond(to: "arc unmount \(mountDir.path)", stdout: hint, exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        do {
            try await manager.remove(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", hint))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(runner.callLines, ["arc unmount \(mountDir.path)"])
        XCTAssertTrue(exists(store))
        XCTAssertTrue(exists(store.appendingPathComponent("blob.bin")))
        XCTAssertTrue(exists(mountDir))
    }

    func test_removeThrowsWhenUnmountFailsForAnotherReason() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-3")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-3")
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
        let mountDir = try temp.makeDirectory("arcadia_TASK-6")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-6")
        try temp.makeFile(".arc/stores/_arcadia_TASK-6/blob.bin", bytes: 4096)
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

    /// A repeat of a stale list: `arc` no longer knows the mount, the store is gone and the mount
    /// directory goes with it. There is nothing left to fail at, so this is not an error.
    func test_removeSucceedsWhenForgetFailsAndNothingIsLeftToRemove() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-7")
        let store = temp.url.appendingPathComponent(".arc/stores/_arcadia_TASK-7")
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount --forget \(mountDir.path)",
            stdout: "Not an arc repository.",
            exitCode: 1
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        try await manager.remove(mount) { _ in }

        XCTAssertFalse(exists(store))
        XCTAssertFalse(exists(mountDir))
    }

    /// The genuine failure: `arc` refused and the store is still on disk afterwards.
    func test_removeThrowsWhenForgetFailsAndStoreCannotBeRemoved() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-11")
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-11")
        try temp.makeFile(".arc/stores/_arcadia_TASK-11/blob.bin", bytes: 4096)
        let runner = FakeCommandRunner()
        runner.respond(
            to: "arc unmount --forget \(mountDir.path)",
            stdout: "Not an arc repository.",
            exitCode: 1
        )
        let manager = ArcMountManager(
            runner: runner,
            home: temp.url,
            fileManager: UnremovableFileManager()
        )
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        do {
            try await manager.remove(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount --forget", "Not an arc repository."))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(exists(store))
    }

    func test_removeRefusesStoreOutsideArcStores() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let outside = try TemporaryDirectory()
        defer { outside.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-8")
        let store = try outside.makeDirectory("evil")
        try outside.makeFile("evil/precious.bin", bytes: 512)
        let runner = FakeCommandRunner()
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
        XCTAssertTrue(runner.callLines.isEmpty)
        XCTAssertTrue(logged.contains(store.path))
    }

    /// Containment is lexical, so `<stores>/linkdir/victim` looks like it lives in the stores root
    /// even when `linkdir` points anywhere else on the disk.
    func test_removeRefusesStoreBehindASymlinkedAncestor() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-12")
        try temp.makeDirectory(".arc/stores")
        let outside = try temp.makeDirectory("outside")
        let precious = try temp.makeFile("outside/victim/precious.bin", bytes: 512)
        _ = try temp.makeSymlink(".arc/stores/linkdir", to: outside)
        let store = temp.url.appendingPathComponent(".arc/stores/linkdir/victim")
        let runner = FakeCommandRunner()
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
        XCTAssertTrue(exists(precious))
        XCTAssertTrue(exists(outside.appendingPathComponent("victim")))
        XCTAssertTrue(runner.callLines.isEmpty)
        XCTAssertTrue(logged.contains(store.path))
    }

    /// Unlinking a symlinked store would leave every byte behind it in place while the log claimed
    /// the space was freed, so the store itself has to be a real directory.
    func test_removeRefusesStoreThatIsItselfASymlink() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-13")
        try temp.makeDirectory(".arc/stores")
        let target = try temp.makeDirectory("elsewhere")
        let precious = try temp.makeFile("elsewhere/precious.bin", bytes: 512)
        let store = try temp.makeSymlink(".arc/stores/_arcadia_TASK-13", to: target)
        let runner = FakeCommandRunner()
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
        XCTAssertTrue(exists(precious))
        XCTAssertTrue(exists(store))
        XCTAssertTrue(runner.callLines.isEmpty)
        XCTAssertTrue(logged.contains(store.path))
    }

    /// Two `arc` invocations run between validating the store path and deleting it, so the check
    /// that guards the delete has to be the one next to `removeItem`, not only the one up front.
    func test_removeRefusesAStoreThatTurnsIntoASymlinkWhileArcRuns() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-14")
        try temp.makeDirectory(".arc/stores")
        let target = try temp.makeDirectory("elsewhere")
        let precious = try temp.makeFile("elsewhere/precious.bin", bytes: 512)
        let store = temp.url.appendingPathComponent(".arc/stores/_arcadia_TASK-14")
        let runner = SideEffectCommandRunner {
            try? FileManager.default.createSymbolicLink(at: store, withDestinationURL: target)
        }
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: store.path, objectStore: "/o")

        do {
            try await manager.remove(mount) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .refusedPath(store.path))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(exists(precious))
        XCTAssertTrue(exists(target))
    }

    func test_removeKeepsNonEmptyDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_TASK-1")
        try temp.makeFile("arcadia_TASK-1/leftover", bytes: 1)
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
              {"status":"mounted","mount":"/Users/tester/arcadia_TASK-10","store":"/s","object-store":"/o"},
              {"status":"mounted","mount":"/Users/tester/arcadia","store":"/s","object-store":"/o"},
              {"status":"mounted","mount":"/Users/tester/arcadia_TASK-2","store":"/s","object-store":"/o"}
            ]
            """
        )
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        let mounts = try await manager.mounts()

        XCTAssertEqual(mounts.map(\.name), [
            "arcadia",
            "arcadia_TASK-2",
            "arcadia_TASK-10",
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

    func test_listDoesNotMeasureStoreSizes() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        let otherMount = temp.url.appendingPathComponent("arcadia_TASK-1").path
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-1")
        try temp.makeFile(".arc/stores/_arcadia_TASK-1/blob.bin", bytes: 4096)
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
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: temp.url)

        let date = manager.lastUsed(ofStore: store.path)

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
    }

    func test_lastUsedFallsBackToStoreRootWhenMetadataIsMissing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory("store")
        let expected = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: store.path)
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: temp.url)

        let date = manager.lastUsed(ofStore: store.path)

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
    }

    func test_lastUsedIsNilWhenStoreIsMissing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: temp.url)

        let date = manager.lastUsed(ofStore: temp.url.appendingPathComponent("gone").path)

        XCTAssertNil(date)
    }

    /// `arc` may spell a store with a `~`, and `URL(fileURLWithPath:)` would resolve that against
    /// the current directory instead of the home this manager was given.
    func test_lastUsedNormalizesTildeSpelledStore() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let metadata = try temp.makeDirectory(".arc/stores/_arcadia_TASK-1/.arc")
        let expected = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: metadata.path)
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: temp.url)

        let date = manager.lastUsed(ofStore: "~/.arc/stores/_arcadia_TASK-1")

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
    }

    func test_listReadsLastUsedFromStoreMetadata() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = try temp.makeDirectory(".arc/stores/_arcadia_TASK-1")
        let metadata = try temp.makeDirectory(".arc/stores/_arcadia_TASK-1/.arc")
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: metadata.path)
        let runner = FakeCommandRunner()
        let used = temp.url.appendingPathComponent("arcadia_TASK-1").path
        let missing = temp.url.appendingPathComponent("arcadia_TASK-2").path
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

/// Succeeds at everything and changes the filesystem while it does, so a test can act inside the
/// window between validating a path and using it.
private final class SideEffectCommandRunner: CommandRunning, @unchecked Sendable {
    private let sideEffect: @Sendable () -> Void

    init(sideEffect: @escaping @Sendable () -> Void) {
        self.sideEffect = sideEffect
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        sideEffect()
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// Refuses to delete anything, so a test can reach the branch where the store survives a removal
/// attempt without depending on filesystem permissions.
private final class UnremovableFileManager: FileManager, @unchecked Sendable {
    override func removeItem(atPath path: String) throws {
        throw CocoaError(.fileWriteNoPermission)
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
