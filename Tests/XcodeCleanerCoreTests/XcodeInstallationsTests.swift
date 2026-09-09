import XCTest
@testable import XcodeCleanerCore

final class XcodeInstallationsTests: XCTestCase {
    func test_marksActiveXcodeFromDeveloperDir() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let active = try temp.makeDirectory("Xcode-26.2.0.app/Contents/Developer")
        let old = try temp.makeDirectory("Xcode-16.4.app/Contents/Developer")
        try temp.makeDirectory("Xcodes.app")
        try temp.makeDirectory("Safari.app")

        let installations = XcodeInstallationScanner.installations(
            in: temp.url,
            activeDeveloperDir: active.path
        )

        XCTAssertEqual(installations.map(\.name).sorted(), ["Xcode-16.4.app", "Xcode-26.2.0.app"])
        XCTAssertEqual(installations.first { $0.name == "Xcode-26.2.0.app" }?.isActive, true)
        XCTAssertEqual(installations.first { $0.name == "Xcode-16.4.app" }?.isActive, false)
        XCTAssertEqual(old.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Xcode-16.4.app")
    }

    func test_marksBothActiveThroughSymlinkedXcodeApp() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeDirectory("Xcode-26.2.0.app/Contents/Developer")
        _ = try temp.makeSymlink("Xcode.app", to: temp.url.appendingPathComponent("Xcode-26.2.0.app"))
        let activeDeveloperDir = temp.url.appendingPathComponent("Xcode.app/Contents/Developer").path

        let installations = XcodeInstallationScanner.installations(
            in: temp.url,
            activeDeveloperDir: activeDeveloperDir
        )

        XCTAssertEqual(installations.first { $0.name == "Xcode.app" }?.isActive, true)
        XCTAssertEqual(installations.first { $0.name == "Xcode-26.2.0.app" }?.isActive, true)
    }

    func test_filtersXcodeAppsByNameShape() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeDirectory("Xcode.app/Contents/Developer")
        try temp.makeDirectory("Xcode-16.4.app/Contents/Developer")
        try temp.makeDirectory("Xcode-beta.app/Contents/Developer")
        try temp.makeDirectory("Xcode 26.2.app/Contents/Developer")
        try temp.makeDirectory("Xcodes.app")
        try temp.makeDirectory("XcodeCleaner.app")
        try temp.makeDirectory("Safari.app")

        let installations = XcodeInstallationScanner.installations(in: temp.url, activeDeveloperDir: "/none")

        XCTAssertEqual(
            installations.map(\.name).sorted(),
            ["Xcode 26.2.app", "Xcode-16.4.app", "Xcode-beta.app", "Xcode.app"]
        )
    }

    func test_toolchainsProtectSwiftLatestAndItsTarget() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let latest = try temp.makeDirectory("swift-6.3.3-RELEASE.xctoolchain")
        try temp.makeDirectory("swift-5.9-RELEASE.xctoolchain")
        _ = try temp.makeSymlink("swift-latest.xctoolchain", to: latest)

        let toolchains = XcodeInstallationScanner.toolchains(in: temp.url)

        let byName = Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["swift-6.3.3-RELEASE.xctoolchain", "swift-5.9-RELEASE.xctoolchain", "swift-latest.xctoolchain"])
        XCTAssertEqual(byName["swift-latest.xctoolchain"]?.isProtected, true)
        XCTAssertEqual(byName["swift-6.3.3-RELEASE.xctoolchain"]?.isProtected, true)
        XCTAssertEqual(byName["swift-5.9-RELEASE.xctoolchain"]?.isProtected, false)
    }

    func test_danglingSwiftLatestSymlinkProtectsOnlyItself() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeDirectory("swift-5.9-RELEASE.xctoolchain")
        let missingTarget = temp.url.appendingPathComponent("swift-9.9-RELEASE.xctoolchain")
        _ = try temp.makeSymlink("swift-latest.xctoolchain", to: missingTarget)

        let toolchains = XcodeInstallationScanner.toolchains(in: temp.url)

        let byName = Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["swift-5.9-RELEASE.xctoolchain", "swift-latest.xctoolchain"])
        XCTAssertEqual(byName["swift-latest.xctoolchain"]?.isProtected, true)
        XCTAssertEqual(byName["swift-5.9-RELEASE.xctoolchain"]?.isProtected, false)
    }

    func test_toolchainSizeDecidedBySymlinkNotName() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let latest = try temp.makeDirectory("swift-6.3.3-RELEASE.xctoolchain")
        try temp.makeFile("swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift", bytes: 4096)
        _ = try temp.makeSymlink("swift-latest.xctoolchain", to: latest)

        let toolchains = XcodeInstallationScanner.toolchains(in: temp.url)

        let byName = Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0) })
        XCTAssertEqual(byName["swift-latest.xctoolchain"]?.sizeBytes, 0)
        XCTAssertGreaterThanOrEqual(byName["swift-6.3.3-RELEASE.xctoolchain"]?.sizeBytes ?? 0, 4096)
    }

    func test_activeDeveloperDirUsesXcodeSelect() async throws {
        let runner = FakeCommandRunner()
        runner.respond(to: "xcode-select -p", stdout: "/Applications/Xcode-26.2.0.app/Contents/Developer\n")

        let dir = try await XcodeInstallationScanner.activeDeveloperDir(runner: runner)

        XCTAssertEqual(dir, "/Applications/Xcode-26.2.0.app/Contents/Developer")
    }

    func test_itemsAreTrashAndDestructive() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try temp.makeDirectory("Xcode-16.4.app/Contents/Developer")
        let installation = XcodeInstallationScanner.installations(in: temp.url, activeDeveloperDir: "/none")[0]
        let toolchainDir = try temp.makeDirectory("swift-5.9-RELEASE.xctoolchain")
        let toolchain = XcodeInstallationScanner.toolchains(in: temp.url)[0]

        let installationURL = URL(
            fileURLWithPath: old.deletingLastPathComponent().deletingLastPathComponent().path,
            isDirectory: false
        )
        XCTAssertEqual(installation.makeItem().action, .trash(installationURL))
        XCTAssertEqual(installation.makeItem().kind, .xcodeApps)
        XCTAssertTrue(installation.makeItem().isDestructive)
        XCTAssertEqual(toolchain.makeItem().action, .trash(toolchainDir))
        XCTAssertEqual(toolchain.makeItem().kind, .toolchains)
    }
}
