import Foundation

public enum ProjectCacheScanner {
    public static func allowedDirectories(mounts: [ArcMountInfo], cachePaths: CachePaths) -> [URL] {
        let inMounts = mounts
            .filter { $0.mount.isMounted }
            .flatMap { cachePaths.projectCacheDirectories(inMount: URL(fileURLWithPath: $0.mount.mount)) }
        return cachePaths.globalProjectCaches + inMounts
    }

    public static func items(
        mounts: [ArcMountInfo],
        cachePaths: CachePaths,
        fileManager: FileManager = .default
    ) -> [CleanupItem] {
        CacheItemBuilder.items(
            kind: .projectCaches,
            directories: allowedDirectories(mounts: mounts, cachePaths: cachePaths),
            fileManager: fileManager
        )
    }
}
