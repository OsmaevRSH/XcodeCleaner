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

    public static func current(
        for url: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> DiskSpace {
        let values = try url.resourceValues(forKeys: [
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
