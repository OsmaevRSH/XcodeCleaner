import XCTest
@testable import XcodeCleanerCore

final class ArchivesTests: XCTestCase {
    private func makeArchive(_ temp: TemporaryDirectory, _ relative: String, daysAgo: Int) throws -> URL {
        let url = try temp.makeDirectory(relative)
        try temp.makeFile("\(relative)/Info.plist", bytes: 100)
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        return url
    }

    func test_findsArchivesTwoLevelsDeep() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try makeArchive(temp, "2026-01-01/App 01.01.26.xcarchive", daysAgo: 100)
        let fresh = try makeArchive(temp, "2026-09-01/App 01.09.26.xcarchive", daysAgo: 3)
        try temp.makeDirectory("2026-09-01/NotAnArchive")

        let archives = ArchiveScanner.archives(in: temp.url)

        XCTAssertEqual(Set(archives.map(\.url.path)), [old.path, fresh.path])
        XCTAssertTrue(archives.allSatisfy { $0.sizeBytes == nil }, "the scan must not walk archives")
    }

    func test_filtersByAge() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try makeArchive(temp, "2026-01-01/Old.xcarchive", daysAgo: 100)
        _ = try makeArchive(temp, "2026-09-01/Fresh.xcarchive", daysAgo: 3)
        let archives = ArchiveScanner.archives(in: temp.url)

        let stale = ArchiveScanner.olderThan(days: 30, archives)

        XCTAssertEqual(stale.map(\.url.path), [old.path])
    }

    func test_makeItemIsDestructiveTrash() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try makeArchive(temp, "2026-01-01/Old.xcarchive", daysAgo: 100)
        let entry = ArchiveScanner.archives(in: temp.url)[0]

        let item = entry.makeItem()

        XCTAssertEqual(item.kind, .archives)
        XCTAssertEqual(item.action, .trash(old))
        XCTAssertTrue(item.isDestructive)
        XCTAssertEqual(item.title, "Old.xcarchive")
    }

    func test_missingDirectoryYieldsEmpty() {
        XCTAssertEqual(ArchiveScanner.archives(in: URL(fileURLWithPath: "/nonexistent/\(UUID())")), [])
    }

    func test_freshArchiveExcludedAtZeroDaysThreshold() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        _ = try makeArchive(temp, "2026-09-01/Fresh.xcarchive", daysAgo: 0)
        let entry = ArchiveScanner.archives(in: temp.url)[0]

        XCTAssertTrue(ArchiveScanner.olderThan(days: 0, now: entry.createdAt, [entry]).isEmpty)
    }
}
