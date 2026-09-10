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

    public init(runner: any CommandRunning, cachePaths: CachePaths, fileManager: FileManager = .default) {
        self.runner = runner
        self.cachePaths = cachePaths
        self.fileManager = fileManager
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

        let projectDirectories = ProjectCacheScanner.allowedDirectories(mounts: mountInfos, cachePaths: paths)
        async let projectItems = CacheItemBuilder.items(
            kind: .projectCaches,
            directories: projectDirectories,
            fileManager: FileManager()
        )
        result.projectCacheItems = await projectItems

        result.warnings = [simulatorWarning, xcodeWarning, mountWarning].compactMap { $0 }
            + symlinkWarnings(projectDirectories: projectDirectories)
        return result
    }

    /// Measures every size the scan left unknown, calling back per measurement as it completes.
    /// Keys are `CleanupItem.id` for cleanup items and `ArcMountInfo.id` for Arcadia stores.
    /// Honours task cancellation between measurements.
    ///
    /// Walking these trees is what used to make a scan take half a minute — sizing the Arcadia
    /// stores alone costs tens of seconds, and neither `du` nor more parallelism makes it
    /// meaningfully faster. So the walks happen here instead, after the list is on screen, and
    /// each answer is handed over the moment it is ready.
    public func measureSizes(
        for result: ScanResult,
        onSize: @escaping @Sendable (String, Int64) -> Void
    ) async {
        let targets = Self.measurementTargets(for: result)
        guard targets.isEmpty == false, Task.isCancelled == false else { return }
        await withTaskGroup(of: (String, Int64).self) { group in
            for target in targets {
                // A freshly created `FileManager` is owned by the child task alone, so nothing has
                // to cross an isolation boundary and `group.cancelAll()` reaches the walk itself:
                // `DirectorySizer` polls `Task.isCancelled`, which a detached task would not see.
                group.addTask(priority: .utility) {
                    (target.id, DirectorySizer.size(of: target.url, fileManager: FileManager()))
                }
            }
            for await (id, bytes) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                onSize(id, bytes)
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
    public func makeDeleter(for result: ScanResult) -> SafeDeleter {
        let trashableParents = Set(
            (result.xcodes.map(\.url) + result.toolchains.map(\.url) + result.archives.map(\.url))
                .map { $0.deletingLastPathComponent() }
        )
        return SafeDeleter(
            clearableDirectories: cachePaths.allClearable
                + ProjectCacheScanner.allowedDirectories(mounts: result.mounts, cachePaths: cachePaths),
            trashableParents: Array(trashableParents)
        )
    }

    /// The directories the item builders silently drop because they sit on or behind a symlink,
    /// reported once each even though the global project caches appear in both lists.
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
