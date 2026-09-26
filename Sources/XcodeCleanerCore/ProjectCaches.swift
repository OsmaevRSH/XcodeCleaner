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

    /// How deep below a root the walk looks. The root is depth 0, so a `.build` whose parent is
    /// eight components down is still found.
    public static let defaultMaxDepth = 8

    /// How long one root may be walked. A folder as broad as `~` can hold more than any walk should
    /// read; past this point the root is abandoned with a word in the log, and the others go on.
    public static let defaultTimeBudget: Duration = .seconds(30)

    /// What a discovery walk found, and what the user should hear about how it went.
    public struct Discovery: Sendable, Equatable {
        /// Sorted by path, so the list does not reshuffle between scans.
        public var directories: [CacheDirectory]
        /// One line per root that ran out of time, in the order the roots were walked.
        public var warnings: [String]

        public init(directories: [CacheDirectory] = [], warnings: [String] = []) {
            self.directories = directories
            self.warnings = warnings
        }
    }

    /// Finds every SwiftPM `.build` directory under the configured roots of the mounted mounts.
    /// Bounded in depth and time, and cancellable: this walks a FUSE filesystem, where a cold read
    /// of one root can take seconds.
    ///
    /// Only mounted mounts are walked. An unmounted one has nothing behind its directory to look
    /// at, and the bytes its `.build` directories will occupy once it is mounted again live in the
    /// mount's store, which the Arcadia tab already measures and deletes.
    ///
    /// - Parameters:
    ///   - timeBudget: per root, not per call; see `defaultTimeBudget`.
    ///   - now: the clock the budget is measured on. Injected so a test can run a root out of time
    ///     without waiting for it.
    ///   - deviceID: the filesystem an item lives on. Injected because every temporary directory a
    ///     test can create shares one device, so the boundary is otherwise untestable.
    public static func discoverBuildDirectories(
        mounts: [ArcMountInfo],
        cachePaths: CachePaths,
        maxDepth: Int = defaultMaxDepth,
        timeBudget: Duration = defaultTimeBudget,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        deviceID: (URL) -> Int? = ProjectCacheScanner.deviceID(of:),
        fileManager: FileManager = .default
    ) -> Discovery {
        var discovery = Discovery()
        var seen = Set<String>()
        let limits = Limits(
            maxDepth: maxDepth,
            timeBudget: timeBudget,
            skippedPaths: skippedPaths(home: cachePaths.home)
        )
        walking: for info in mounts where info.mount.isMounted {
            let mount = URL(fileURLWithPath: info.mount.mount).standardizedFileURL
            for root in cachePaths.projectSearchRoots {
                guard Task.isCancelled == false else { break walking }
                let url = mount.appendingPathComponent(root)
                let walk = walk(
                    root: url,
                    relativePath: root,
                    title: { _, relativePath in "\(info.mount.name) · \(relativePath)" },
                    limits: limits,
                    now: now,
                    deviceID: deviceID,
                    fileManager: fileManager
                )
                // Configured roots may nest, and then one `.build` is reachable through both.
                discovery.directories += walk.found.filter { seen.insert($0.url.path).inserted }
                if walk.ranOutOfTime {
                    discovery.warnings.append(budgetWarning(url, home: cachePaths.home, budget: timeBudget))
                }
            }
        }
        discovery.directories.sort { $0.url.path < $1.url.path }
        return discovery
    }

    /// Finds every SwiftPM `.build` directory under folders the user picked, anywhere on the disk.
    /// Same walk, same bounds and the same two safety rules as inside a mount; each `.build` is
    /// titled by its own path with the home shortened to `~`, because outside a mount there is no
    /// better name for it.
    ///
    /// Nothing here depends on `arc`: this is the half of the discovery that works on a machine
    /// without Arcadia.
    ///
    /// A folder reached through a symlink is not walked: every `.build` under it would be spelled
    /// through the link, and the deleter's allowlist refuses such paths — so they could only ever be
    /// offered and then not cleaned. `Scanner.scan()` warns about such a folder instead.
    public static func discoverBuildDirectories(
        inFolders folders: [URL],
        home: URL,
        maxDepth: Int = defaultMaxDepth,
        timeBudget: Duration = defaultTimeBudget,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        deviceID: (URL) -> Int? = ProjectCacheScanner.deviceID(of:),
        fileManager: FileManager = .default
    ) -> Discovery {
        var discovery = Discovery()
        var seen = Set<String>()
        let limits = Limits(maxDepth: maxDepth, timeBudget: timeBudget, skippedPaths: skippedPaths(home: home))
        for folder in folders.map(\.standardizedFileURL) {
            guard Task.isCancelled == false else { break }
            guard folder.resolvingSymlinksInPath().path == folder.path else { continue }
            let walk = walk(
                root: folder,
                relativePath: "",
                title: { url, _ in CachePaths.displayPath(url, home: home) },
                limits: limits,
                now: now,
                deviceID: deviceID,
                fileManager: fileManager
            )
            // `~` and `~/Developer` both reach the packages under `~/Developer`.
            discovery.directories += walk.found.filter { seen.insert($0.url.path).inserted }
            if walk.ranOutOfTime {
                discovery.warnings.append(budgetWarning(folder, home: home, budget: timeBudget))
            }
        }
        discovery.directories.sort { $0.url.path < $1.url.path }
        return discovery
    }

    /// The filesystem an item lives on: `st_dev` from `lstat`, the same number `SafeDeleter` reads
    /// as `.systemNumber`. `lstat`, so that a symlink answers for itself — the walk never follows
    /// one anyway. Nil when the item cannot be read, which the walk treats as foreign.
    public static func deviceID(of url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_dev)
    }

    /// The directory `swift build` leaves behind.
    private static let buildDirectoryName = ".build"

    /// What has to sit next to a `.build` for it to count. In an arbitrary folder `.build` is a
    /// common enough name for things SwiftPM never made, and the cleanup empties what it finds.
    private static let manifestName = "Package.swift"

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

    /// `~/Library` and `~/.Trash`: walking them is slow — `~/Library` alone holds hundreds of
    /// thousands of directories — and neither ever holds a project. Only these two exact paths:
    /// a `Library` folder inside a project is walked like any other.
    static func skippedPaths(home: URL) -> Set<String> {
        let home = home.standardizedFileURL
        return [home.appendingPathComponent("Library").path, home.appendingPathComponent(".Trash").path]
    }

    private struct Limits {
        let maxDepth: Int
        let timeBudget: Duration
        let skippedPaths: Set<String>
    }

    private static func budgetWarning(_ root: URL, home: URL, budget: Duration) -> String {
        "Поиск в \(CachePaths.displayPath(root, home: home)) остановлен через \(budget.components.seconds) с — укажите папку точнее"
    }

    /// One root, walked depth-bounded: the root itself is depth 0, so a cache at `maxDepth`
    /// components below it is still found and anything deeper is not.
    ///
    /// Two rules keep the walk to what it is looking for. A `.build` counts only with a regular
    /// `Package.swift` next to it. And the walk stays on the root's own filesystem: a directory on
    /// another device — an Arcadia FUSE mount under `~`, a network share, an external drive — is
    /// neither entered nor reported. The boundary is the root's device, so a root that is itself on
    /// an external drive is walked in full.
    ///
    /// A root that cannot be read, or does not exist, has no device and yields nothing: mounts
    /// hold different subsets of the monorepo, and a root not checked out here is not an error.
    private static func walk(
        root: URL,
        relativePath: String,
        title: (URL, String) -> String,
        limits: Limits,
        now: () -> ContinuousClock.Instant,
        deviceID: (URL) -> Int?,
        fileManager: FileManager
    ) -> (found: [CacheDirectory], ranOutOfTime: Bool) {
        guard let rootDevice = deviceID(root) else { return ([], false) }
        let deadline = now() + limits.timeBudget
        var found: [CacheDirectory] = []
        var pending: [(url: URL, relativePath: String, depth: Int)] = [(root, relativePath, 0)]
        while let current = pending.popLast() {
            guard Task.isCancelled == false else { return (found, false) }
            guard current.depth < limits.maxDepth else { continue }
            guard now() < deadline else { return (found, true) }
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
                guard limits.skippedPaths.contains(url.path) == false, deviceID(url) == rootDevice else {
                    continue
                }
                let relativePath = current.relativePath.isEmpty ? name : "\(current.relativePath)/\(name)"
                guard name != buildDirectoryName else {
                    // A `.build` is the answer, not a place to keep looking: SwiftPM checks
                    // packages out inside it, and each of those has a `.build` of its own that the
                    // outer one already contains. Without a manifest next to it, it is not an
                    // answer either — and still not a place to look.
                    if children.contains(where: isManifest) {
                        found.append(CacheDirectory(url: url, title: title(url, relativePath)))
                    }
                    continue
                }
                pending.append((url, relativePath, current.depth + 1))
            }
        }
        return (found, false)
    }

    private static let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]

    /// A directory, and not a symlink to one: `.isDirectoryKey` answers for the *target* of a link,
    /// so the link itself has to be rejected on `.isSymbolicLinkKey` explicitly. Following one
    /// would walk out of the mount, or, for a link to an ancestor, in circles; and a `.build` that
    /// is itself a link is one whose contents belong to something else.
    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// `Package.swift` as a regular file. A directory of that name is not a manifest, and a symlink
    /// of that name may be the manifest of some other package entirely.
    private static func isManifest(_ url: URL) -> Bool {
        guard url.lastPathComponent == manifestName,
              let values = try? url.resourceValues(forKeys: resourceKeys)
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isSkipped(_ name: String) -> Bool {
        skippedDirectoryNames.contains(name) || skippedDirectorySuffixes.contains { name.hasSuffix($0) }
    }
}
