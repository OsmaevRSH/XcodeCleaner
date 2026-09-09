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
}
