import XCTest
@testable import XcodeCleanerCore

final class ProjectCachesTests: XCTestCase {
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
            ArcMountInfo(mount: ArcMount(status: .mounted, mount: mounted.path, store: "/s", objectStore: "/o"), storeSizeBytes: nil, isMain: true, sharesMainObjectStore: true),
            ArcMountInfo(mount: ArcMount(status: .unmounted, mount: unmounted.path, store: "/s", objectStore: "/o"), storeSizeBytes: 0, isMain: false, sharesMainObjectStore: true),
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
}
