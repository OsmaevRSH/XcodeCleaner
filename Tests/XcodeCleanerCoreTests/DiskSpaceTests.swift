import XCTest
@testable import XcodeCleanerCore

final class DiskSpaceTests: XCTestCase {
    func test_usedIsTotalMinusAvailable() {
        let space = DiskSpace(total: 1000, available: 250)
        XCTAssertEqual(space.used, 750)
    }

    func test_currentHomeVolumeHasSaneNumbers() throws {
        let space = try DiskSpace.current()
        XCTAssertGreaterThan(space.total, 0)
        XCTAssertLessThanOrEqual(space.available, space.total)
    }

    /// Значения ресурсов кэшируются на экземпляре `URL`, поэтому повторный запрос
    /// через тот же экземпляр возвращал объём, каким он был до удаления файлов.
    /// Приложение переиспользует один `URL` домашнего каталога, и из-за этого
    /// свободное место в шапке не менялось после очистки.
    func test_currentSeesDeletionsThroughARepeatedlyUsedURL() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let ballast = temp.url.appendingPathComponent("ballast.bin")
        let baseline = try DiskSpace.current(for: home)

        FileManager.default.createFile(atPath: ballast.path, contents: nil)
        let handle = try FileHandle(forWritingTo: ballast)
        let chunk = Data(count: 8 * 1024 * 1024)
        for _ in 0 ..< 16 {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
        let filled = try DiskSpace.current(for: home)

        try FileManager.default.removeItem(at: ballast)
        let restored = try DiskSpace.current(for: home)

        XCTAssertLessThan(filled.available, baseline.available, "запись 128 МБ должна быть видна")
        XCTAssertGreaterThan(restored.available, filled.available, "удаление должно быть видно через тот же URL")
    }
}
