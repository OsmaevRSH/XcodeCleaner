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

    /// Finds every SwiftPM `.build` directory under the configured roots of the mounted mounts.
    /// Bounded in depth and cancellable: this walks a FUSE filesystem, where a cold read of one
    /// root can take seconds.
    ///
    /// Only mounted mounts are walked. An unmounted one has nothing behind its directory to look
    /// at, and the bytes its `.build` directories will occupy once it is mounted again live in the
    /// mount's store, which the Arcadia tab already measures and deletes.
    ///
    /// Results are sorted by path, so the list does not reshuffle between scans.
    public static func discoverBuildDirectories(
        mounts: [ArcMountInfo],
        cachePaths: CachePaths,
        maxDepth: Int = 8,
        fileManager: FileManager = .default
    ) -> [CacheDirectory] {
        var found: [CacheDirectory] = []
        var seen = Set<String>()
        for info in mounts where info.mount.isMounted {
            let mount = URL(fileURLWithPath: info.mount.mount).standardizedFileURL
            for root in cachePaths.projectSearchRoots {
                guard Task.isCancelled == false else { return found.sorted { $0.url.path < $1.url.path } }
                let discovered = discover(
                    root: mount.appendingPathComponent(root),
                    relativePath: root,
                    mountName: info.mount.name,
                    maxDepth: maxDepth,
                    fileManager: fileManager
                )
                // Configured roots may nest, and then one `.build` is reachable through both.
                found += discovered.filter { seen.insert($0.url.path).inserted }
            }
        }
        return found.sorted { $0.url.path < $1.url.path }
    }

    /// The directory `swift build` leaves behind.
    private static let buildDirectoryName = ".build"

    /// Directories the walk never enters. Version-control and tool metadata hold no packages;
    /// `Derived` and `DerivedData` are Tuist outputs already offered by path; and `node_modules`
    /// together with those two are the deep trees that would make the walk expensive.
    static let skippedDirectoryNames: Set<String> = [
        ".git", ".arc", ".swiftpm", ".overlay_v2", "node_modules", "DerivedData", "Derived",
        "xcuserdata",
    ]

    /// Bundles. What is inside them is a build product, never a package somebody ran `swift build`
    /// in, and `.xcodeproj` in particular is a directory deep enough to be worth skipping.
    static let skippedDirectorySuffixes = [".xcodeproj", ".xcworkspace", ".framework", ".app"]

    /// One root, walked breadth-unaware but depth-bounded: the root itself is depth 0, so a cache
    /// at `maxDepth` components below it is still found and anything deeper is not.
    private static func discover(
        root: URL,
        relativePath: String,
        mountName: String,
        maxDepth: Int,
        fileManager: FileManager
    ) -> [CacheDirectory] {
        var found: [CacheDirectory] = []
        var pending: [(url: URL, relativePath: String, depth: Int)] = [(root, relativePath, 0)]
        // A missing root simply yields nothing to descend into: mounts hold different subsets of
        // the monorepo, and a root that is not checked out here is not an error.
        while let current = pending.popLast() {
            guard Task.isCancelled == false else { return found }
            guard current.depth < maxDepth else { continue }
            let children = (try? fileManager.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: Array(resourceKeys),
                // Never `.skipsHiddenFiles`: the directory being looked for is hidden itself.
                options: []
            )) ?? []
            for child in children {
                let name = child.lastPathComponent
                guard isSkipped(name) == false, isRealDirectory(child) else { continue }
                // Spelled under the parent rather than taken as `contentsOfDirectory` returned it:
                // that call reports children under the *resolved* parent path, which turns
                // `/var/folders/…` into `/private/var/…`. The same file either way, but the
                // allowlist these paths end up in is compared as strings.
                let url = current.url.appendingPathComponent(name)
                let relativePath = "\(current.relativePath)/\(name)"
                guard name != buildDirectoryName else {
                    // A `.build` is the answer, not a place to keep looking: SwiftPM checks
                    // packages out inside it, and each of those has a `.build` of its own that the
                    // outer one already contains.
                    found.append(CacheDirectory(url: url, title: "\(mountName) · \(relativePath)"))
                    continue
                }
                pending.append((url, relativePath, current.depth + 1))
            }
        }
        return found
    }

    private static let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

    /// A directory, and not a symlink to one: `.isDirectoryKey` answers for the *target* of a link,
    /// so the link itself has to be rejected on `.isSymbolicLinkKey` explicitly. Following one
    /// would walk out of the mount, or, for a link to an ancestor, in circles; and a `.build` that
    /// is itself a link is one whose contents belong to something else.
    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isSkipped(_ name: String) -> Bool {
        skippedDirectoryNames.contains(name) || skippedDirectorySuffixes.contains { name.hasSuffix($0) }
    }
}
