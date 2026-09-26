import Foundation

public struct ScanResult: Sendable, Equatable {
    public var cacheItems: [CleanupItem] = []
    public var projectCacheItems: [CleanupItem] = []
    public var simulators: SimulatorInventory?
    public var archives: [ArchiveEntry] = []
    public var xcodes: [XcodeInstallation] = []
    public var toolchains: [ToolchainEntry] = []
    public var mounts: [ArcMountInfo] = []
    public var disk: DiskSpace?
    public var warnings: [String] = []

    public init() {}
}

public struct Scanner: Sendable {
    private let runner: any CommandRunning
    private let cachePaths: CachePaths
    // Any injected `FileManager` must be thread-safe (the shared default instance is); it is only
    // read.
    private nonisolated(unsafe) let fileManager: FileManager
    /// Per root; see `ProjectCacheScanner.defaultTimeBudget`. Injectable so a test can watch a
    /// root run out of time without waiting thirty seconds for it.
    private let discoveryTimeBudget: Duration

    public init(
        runner: any CommandRunning,
        cachePaths: CachePaths,
        fileManager: FileManager = .default,
        discoveryTimeBudget: Duration = ProjectCacheScanner.defaultTimeBudget
    ) {
        self.runner = runner
        self.cachePaths = cachePaths
        self.fileManager = fileManager
        self.discoveryTimeBudget = discoveryTimeBudget
    }

    /// Finds everything there is to clean without measuring any of it: no branch of this call
    /// walks a directory tree, so the list is ready in well under a second even on a machine with
    /// twenty Arcadia stores. Every size the scan cannot get for free is left nil and filled in
    /// afterwards by `measureSizes(for:onSize:)`.
    public func scan() async -> ScanResult {
        var result = ScanResult()
        result.disk = try? DiskSpace.current(for: cachePaths.home)

        let paths = cachePaths

        async let caches = Self.cacheItems(cachePaths: paths, fileManager: FileManager())
        async let archives = ArchiveScanner.archives(in: paths.archivesDirectory, fileManager: FileManager())
        async let toolchains = XcodeInstallationScanner.toolchains(
            in: paths.toolchainsDirectory,
            fileManager: FileManager()
        )
        async let simulators = scanSimulators()
        async let xcodes = scanXcodes()
        async let mounts = scanMounts()

        let (inventory, simulatorWarning) = await simulators
        result.simulators = inventory
        let (installations, xcodeWarning) = await xcodes
        result.xcodes = installations
        let (mountInfos, mountWarning) = await mounts
        result.mounts = mountInfos

        result.cacheItems = await caches
        result.archives = await archives
        result.toolchains = await toolchains

        let projectDirectories = ProjectCacheScanner.directories(mounts: mountInfos, cachePaths: paths)
        async let projectItems = CacheItemBuilder.items(
            kind: .projectCaches,
            directories: projectDirectories,
            fileManager: FileManager()
        )
        result.projectCacheItems = await projectItems

        result.warnings = [simulatorWarning, xcodeWarning, mountWarning].compactMap { $0 }
            + symlinkWarnings(projectDirectories: projectDirectories.map(\.url) + paths.projectSearchFolders)
            + missingFolderWarnings()
        return result
    }

    /// Discovers project caches that `scan()` is too fast to look for, reporting each as it is
    /// found. `swift build` leaves a `.build` next to every `Package.swift`, and no fixed list of
    /// paths can know where those packages are — only a walk finds them, and a walk is exactly what
    /// `scan()` must not do: bounded as it is, a cold read of one root inside a FUSE mount costs
    /// seconds. So this runs in the background phase, next to `measureSizes(for:onSize:)`.
    ///
    /// The mounted mounts are walked first, then the folders from `projectSearchFolders`. The
    /// folders do not depend on the mounts at all: with `arc` missing and no mount in the result,
    /// they are still walked.
    ///
    /// Caches already in `result.projectCacheItems` are not reported again, and neither is a cache
    /// reachable from two places — a folder inside a mount root, or two nested folders. The first
    /// report wins, so a `.build` inside a mount keeps the mount's name.
    ///
    /// - Parameters:
    ///   - onDiscover: invoked off the main thread, once per cache, root by root — so the caches of
    ///     the first mount arrive before the last folder has been walked. Cancellation is honoured
    ///     between roots and inside a walk; this function returning is the only signal that no
    ///     more are coming.
    ///   - onWarning: invoked off the main thread for each root that ran out of time, with the line
    ///     the log should show.
    public func discoverProjectCaches(
        for result: ScanResult,
        onDiscover: @escaping @Sendable (CleanupItem) -> Void,
        onWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async {
        let paths = cachePaths
        let budget = discoveryTimeBudget
        var reported = Set(result.projectCacheItems.map(\.id))
        var walks: [@Sendable (FileManager) -> ProjectCacheScanner.Discovery] = []
        for mount in result.mounts where mount.mount.isMounted {
            walks.append { fileManager in
                ProjectCacheScanner.discoverBuildDirectories(
                    mounts: [mount],
                    cachePaths: paths,
                    timeBudget: budget,
                    fileManager: fileManager
                )
            }
        }
        for folder in paths.projectSearchFolders {
            walks.append { fileManager in
                ProjectCacheScanner.discoverBuildDirectories(
                    inFolders: [folder],
                    home: paths.home,
                    timeBudget: budget,
                    fileManager: fileManager
                )
            }
        }
        for walk in walks {
            guard Task.isCancelled == false else { return }
            let (items, warnings) = await Self.run(walk)
            for item in items where reported.insert(item.id).inserted {
                onDiscover(item)
            }
            warnings.forEach(onWarning)
        }
    }

    /// One discovery walk, in a child task for the reason `measureSizes` uses them: the walk is
    /// synchronous and would otherwise block whatever thread this was called on, and a freshly
    /// created `FileManager` is owned by that task alone. Structured, so cancelling the caller
    /// reaches `Task.isCancelled` inside the walk.
    private static func run(
        _ walk: @escaping @Sendable (FileManager) -> ProjectCacheScanner.Discovery
    ) async -> ([CleanupItem], [String]) {
        await withTaskGroup(of: ([CleanupItem], [String]).self) { group in
            group.addTask(priority: .utility) {
                let fileManager = FileManager()
                let discovery = walk(fileManager)
                let items = CacheItemBuilder.items(
                    kind: .projectCaches,
                    directories: discovery.directories,
                    fileManager: fileManager
                )
                return (items, discovery.warnings)
            }
            return await group.next() ?? ([], [])
        }
    }

    /// How many directory walks run at once. Each child task blocks its thread for the whole walk,
    /// so seeding one per target puts a walk on every thread of the cooperative pool and leaves
    /// nothing to run the rest of the app on. Some targets are project caches inside live FUSE
    /// mounts, where a stale mount can park a thread in `readdir` well past the point where
    /// `DirectorySizer`'s cancellation poll could get it back — so this ceiling is also what stops
    /// one hung mount from taking the whole pool with it.
    private static let measurementConcurrency = 4

    /// Measures every size the scan left unknown, calling back per measurement as it completes.
    /// Keys are `CleanupItem.id` for cleanup items and `ArcMountInfo.id` for Arcadia stores.
    ///
    /// Walking these trees is what used to make a scan take half a minute — sizing the Arcadia
    /// stores alone costs tens of seconds, and neither `du` nor more parallelism makes it
    /// meaningfully faster. So the walks happen here instead, after the list is on screen, and
    /// each answer is handed over the moment it is ready.
    ///
    /// - Parameter onSize: invoked off the main thread, on a cooperative-pool thread, in completion
    ///   order rather than target order. The drain loop below is its only caller, so two calls
    ///   never overlap — a `@MainActor` sink still has to hop, but it needs no lock of its own.
    ///   Cancellation is honoured between measurements: ids not reported by then simply stay
    ///   unknown, and this function returning is the only signal that no more are coming.
    public func measureSizes(
        for result: ScanResult,
        onSize: @escaping @Sendable (String, Int64) -> Void
    ) async {
        let targets = Self.measurementTargets(for: result)
        guard targets.isEmpty == false, Task.isCancelled == false else { return }
        await withTaskGroup(of: (String, Int64).self) { group in
            // A freshly created `FileManager` is owned by the child task alone, so nothing has to
            // cross an isolation boundary and `group.cancelAll()` reaches the walk itself:
            // `DirectorySizer` polls `Task.isCancelled`, which a detached task would not see.
            var next = 0
            while next < min(Self.measurementConcurrency, targets.count) {
                let target = targets[next]
                group.addTask(priority: .utility) {
                    (target.id, DirectorySizer.size(of: target.url, fileManager: FileManager()))
                }
                next += 1
            }
            // One walk starts for every result drained, so the group never holds more than
            // `measurementConcurrency` children no matter how many targets there are.
            for await (id, bytes) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                onSize(id, bytes)
                guard next < targets.count else { continue }
                let target = targets[next]
                group.addTask(priority: .utility) {
                    (target.id, DirectorySizer.size(of: target.url, fileManager: FileManager()))
                }
                next += 1
            }
        }
    }

    /// Everything `scan()` left unmeasured, paired with the id the caller knows it by. A toolchain
    /// that is a symlink is already zero and never appears here; neither does the main Arcadia
    /// mount, whose store is not removable.
    private static func measurementTargets(for result: ScanResult) -> [(id: String, url: URL)] {
        var targets: [(id: String, url: URL)] = []
        for item in result.cacheItems + result.projectCacheItems {
            guard item.sizeBytes == nil, case let .clearContents(url) = item.action else { continue }
            targets.append((item.id, url))
        }
        targets += result.archives.filter { $0.sizeBytes == nil }.map { ($0.id, $0.url) }
        targets += result.xcodes.filter { $0.sizeBytes == nil }.map { ($0.id, $0.url) }
        targets += result.toolchains.filter { $0.sizeBytes == nil }.map { ($0.id, $0.url) }
        targets += result.mounts
            .filter { $0.isMain == false && $0.storeSizeBytes == nil }
            .map { ($0.id, URL(fileURLWithPath: $0.mount.store)) }
        return targets
    }

    /// Trashing is only offered for entries the scan actually found, so the allowlist of parents
    /// is derived from those entries rather than from fixed directories: an archive lives in an
    /// `Archives/<day>` folder, never in the archives root, and nothing in `/Applications` becomes
    /// trashable until an Xcode was found there.
    ///
    /// Project caches go in from both directions. The items the result carries cover the ones found
    /// by walking, so a `.build` discovered in the background becomes deletable by being appended
    /// to the result and needs nothing else; the fixed subpaths go in whether or not they existed
    /// at scan time, because Tuist can create them in between.
    public func makeDeleter(for result: ScanResult) -> SafeDeleter {
        let trashableParents = Set(
            (result.xcodes.map(\.url) + result.toolchains.map(\.url) + result.archives.map(\.url))
                .map { $0.deletingLastPathComponent() }
        )
        let foundProjectCaches = result.projectCacheItems.compactMap { item -> URL? in
            guard case let .clearContents(url) = item.action else { return nil }
            return url
        }
        return SafeDeleter(
            clearableDirectories: cachePaths.allClearable
                + ProjectCacheScanner.allowedDirectories(mounts: result.mounts, cachePaths: cachePaths)
                + foundProjectCaches,
            trashableParents: Array(trashableParents)
        )
    }

    /// A search folder that is not there — a drive not plugged in, a project moved away — stays in
    /// the settings and is skipped, and the log says so rather than leaving the user to wonder why
    /// nothing turned up in it.
    private func missingFolderWarnings() -> [String] {
        cachePaths.projectSearchFolders.compactMap { folder in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "Папка для поиска не найдена, пропущена: \(cachePaths.displayPath(folder))"
            }
            return nil
        }
    }

    /// The directories the item builders silently drop because they sit on or behind a symlink,
    /// reported once each even though the global project caches appear in both lists. The search
    /// folders go through here too: the walk refuses one reached through a symlink.
    private func symlinkWarnings(projectDirectories: [URL]) -> [String] {
        let skipped = CacheItemBuilder.symlinkedDirectories(cachePaths.allClearable, fileManager: fileManager)
            + CacheItemBuilder.symlinkedDirectories(projectDirectories, fileManager: fileManager)
        var seen = Set<String>()
        return skipped
            .filter { seen.insert($0.path).inserted }
            .map { "Пропущено, путь проходит через симлинк: \($0.path)" }
    }

    private static func cacheItems(cachePaths: CachePaths, fileManager: FileManager) -> [CleanupItem] {
        CacheItemBuilder.items(kind: .xcodeCaches, directories: cachePaths.xcodeCaches, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .previews, directories: cachePaths.previews, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .deviceSupport, directories: cachePaths.deviceSupport, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .simulatorCaches, directories: cachePaths.simulatorCaches, fileManager: fileManager)
    }

    private func scanSimulators() async -> (SimulatorInventory?, String?) {
        do {
            return (try await SimulatorScanner(runner: runner).inventory(), nil)
        } catch is CancellationError {
            return (nil, nil)
        } catch {
            return (nil, "Симуляторы недоступны: \(error.localizedDescription)")
        }
    }

    private func scanXcodes() async -> ([XcodeInstallation], String?) {
        do {
            let active = try await XcodeInstallationScanner.activeDeveloperDir(runner: runner)
            let applications = cachePaths.applicationsDirectory
            async let installations = XcodeInstallationScanner.installations(
                in: applications,
                activeDeveloperDir: active,
                fileManager: FileManager()
            )
            return (await installations, nil)
        } catch is CancellationError {
            return ([], nil)
        } catch {
            return ([], "xcode-select недоступен: \(error.localizedDescription)")
        }
    }

    private func scanMounts() async -> ([ArcMountInfo], String?) {
        do {
            let manager = ArcMountManager(runner: runner, home: cachePaths.home, fileManager: fileManager)
            return (try await manager.list(), nil)
        } catch is CancellationError {
            return ([], nil)
        } catch {
            return ([], "arc недоступен: \(error.localizedDescription)")
        }
    }
}
