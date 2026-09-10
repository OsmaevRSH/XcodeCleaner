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

    func test_collectsOnlyExistingSubpathsOfMountedMounts() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia_A")
        try temp.makeFile("arcadia_A/mobile/saft/ios/Tuist/.build/x", bytes: 10)
        try temp.makeFile("arcadia_A/mobile/saft/ios/Derived/y", bytes: 10)
        let unmounted = try temp.makeDirectory("arcadia_B")
        try temp.makeFile("arcadia_B/mobile/saft/ios/Tuist/.build/z", bytes: 10)
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
            mounted.appendingPathComponent("mobile/saft/ios/Tuist/.build").path,
            mounted.appendingPathComponent("mobile/saft/ios/Derived").path,
        ])
        XCTAssertTrue(items.allSatisfy { $0.kind == .projectCaches })
        XCTAssertEqual(allowlist.count, 1 + 3)
        XCTAssertTrue(allowlist.contains(mounted.appendingPathComponent("mobile/saft/ios/DerivedData")))
    }

    /// The complaint this exists for: two mounts used to contribute a `.build`, a `Derived` and a
    /// `DerivedData` each, and every row read exactly like the row from the other mount.
    func test_projectCacheRowsNameTheirMount() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let first = try temp.makeDirectory("arcadia")
        let second = try temp.makeDirectory("arcadia_TASK-1")
        for name in ["arcadia", "arcadia_TASK-1"] {
            for subpath in CachePaths.projectCacheSubpaths {
                try temp.makeFile("\(name)/\(subpath)/x", bytes: 10)
            }
        }
        try temp.makeDirectory(".cache/tuist")
        let paths = CachePaths(home: temp.url)
        let mounts = [
            mount(first, status: .mounted, isMain: true),
            mount(second, status: .mounted),
        ]

        let items = ProjectCacheScanner.items(mounts: mounts, cachePaths: paths)

        XCTAssertEqual(items.map(\.title), [
            "Общий кэш Tuist",
            "arcadia · Tuist/.build",
            "arcadia · Derived",
            "arcadia · DerivedData",
            "arcadia_TASK-1 · Tuist/.build",
            "arcadia_TASK-1 · Derived",
            "arcadia_TASK-1 · DerivedData",
        ])
        XCTAssertEqual(Set(items.map(\.title)).count, items.count)
        XCTAssertEqual(
            items.first { $0.title == "arcadia_TASK-1 · Derived" }?.subtitle,
            second.appendingPathComponent("mobile/saft/ios/Derived").path
        )
    }
}
