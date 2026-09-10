import Foundation

public struct DiskSpace: Sendable, Equatable {
    public let total: Int64
    public let available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    public var used: Int64 { total - available }

    public enum Failure: Error, Equatable {
        case unavailable(String)
    }

    /// Свободное место на томе, которому принадлежит `url`.
    ///
    /// Foundation кэширует значения ресурсов на экземпляре `URL`: после удаления
    /// файлов тот же экземпляр продолжает отдавать прежний объём. Приложение
    /// хранит домашний каталог в одном `URL` и спрашивает место до и после
    /// очистки, поэтому запрос идёт через свежий экземпляр с очищенным кэшем.
    public static func current(
        for url: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> DiskSpace {
        var probe = URL(fileURLWithPath: url.path)
        probe.removeAllCachedResourceValues()
        let values = try probe.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else {
            throw Failure.unavailable(url.path)
        }
        return DiskSpace(total: Int64(total), available: available)
    }
}
