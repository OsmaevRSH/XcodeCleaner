import Foundation

public struct ArchiveEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let createdAt: Date
    public let sizeBytes: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public func makeItem() -> CleanupItem {
        CleanupItem(
            id: url.path,
            kind: .archives,
            title: name,
            subtitle: url.deletingLastPathComponent().lastPathComponent,
            action: .trash(url),
            sizeBytes: sizeBytes,
            isDestructive: true
        )
    }
}

public enum ArchiveScanner {
    public static func archives(in directory: URL, fileManager: FileManager = .default) -> [ArchiveEntry] {
        guard let dayFolders = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [ArchiveEntry] = []
        for folder in dayFolders {
            guard let children = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where child.pathExtension == "xcarchive" {
                let created = (try? child.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let url = XcodeInstallationScanner.entryURL(
                    base: directory,
                    components: [folder.lastPathComponent, child.lastPathComponent]
                )
                result.append(ArchiveEntry(
                    url: url,
                    createdAt: created,
                    sizeBytes: DirectorySizer.size(of: child, fileManager: fileManager)
                ))
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    public static func olderThan(days: Int, now: Date = Date(), _ archives: [ArchiveEntry]) -> [ArchiveEntry] {
        let threshold = now.addingTimeInterval(-Double(days) * 86_400)
        return archives.filter { $0.createdAt < threshold }
    }
}
