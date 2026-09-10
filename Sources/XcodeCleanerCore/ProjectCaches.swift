import Foundation

public enum ProjectCacheScanner {
    /// Every project cache worth offering, titled so that two mounts never produce two rows that
    /// read the same.
    public static func directories(mounts: [ArcMountInfo], cachePaths: CachePaths) -> [CacheDirectory] {
        let inMounts = mounts
            .filter { $0.mount.isMounted }
            .flatMap {
                cachePaths.projectCaches(
                    inMount: URL(fileURLWithPath: $0.mount.mount),
                    mountName: $0.mount.name
                )
            }
        return cachePaths.globalProjectCaches + inMounts
    }

    public static func allowedDirectories(mounts: [ArcMountInfo], cachePaths: CachePaths) -> [URL] {
        directories(mounts: mounts, cachePaths: cachePaths).map(\.url)
    }

    public static func items(
        mounts: [ArcMountInfo],
        cachePaths: CachePaths,
        fileManager: FileManager = .default
    ) -> [CleanupItem] {
        CacheItemBuilder.items(
            kind: .projectCaches,
            directories: directories(mounts: mounts, cachePaths: cachePaths),
            fileManager: fileManager
        )
    }
}
