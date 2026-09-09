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

    /// Every sizing pass runs in a child task so that cancelling the scan reaches the tree walks:
    /// `DirectorySizer` polls `Task.isCancelled`, which a detached task would never observe. Each
    /// concurrent walk gets its own `FileManager` instead of sharing the stored one.
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
