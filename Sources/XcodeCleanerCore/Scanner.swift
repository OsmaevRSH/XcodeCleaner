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

/// `FileManager` is not `Sendable`, but only the shared instance — documented as thread-safe — is
/// ever handed to the sizing tasks, so it crosses task boundaries in an explicit box.
private struct ScannerFileManager: @unchecked Sendable {
    let value: FileManager
}

public struct Scanner: Sendable {
    private let runner: any CommandRunning
    private let cachePaths: CachePaths
    // Only `FileManager.default` is ever injected here, and Apple documents the shared instance as
    // thread-safe. A caller-supplied `FileManager` carrying a delegate would not be.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(runner: any CommandRunning, cachePaths: CachePaths, fileManager: FileManager = .default) {
        self.runner = runner
        self.cachePaths = cachePaths
        self.fileManager = fileManager
    }

    /// `DirectorySizer` walks whole trees synchronously, so every sizing pass runs on a detached
    /// utility task: on the cooperative pool a single `DerivedData` scan would occupy a core for
    /// seconds and stall the other scanners that are supposed to run alongside it.
    public func scan() async -> ScanResult {
        var result = ScanResult()
        result.disk = try? DiskSpace.current(for: cachePaths.home)

        let paths = cachePaths
        let files = ScannerFileManager(value: fileManager)

        let cachesTask = Task.detached(priority: .utility) {
            Self.cacheItems(cachePaths: paths, fileManager: files.value)
        }
        let archivesTask = Task.detached(priority: .utility) {
            ArchiveScanner.archives(in: paths.archivesDirectory, fileManager: files.value)
        }
        let toolchainsTask = Task.detached(priority: .utility) {
            XcodeInstallationScanner.toolchains(in: paths.toolchainsDirectory, fileManager: files.value)
        }

        async let simulators = scanSimulators()
        async let xcodes = scanXcodes()
        async let mounts = scanMounts()

        let (inventory, simulatorWarning) = await simulators
        result.simulators = inventory
        let (installations, xcodeWarning) = await xcodes
        result.xcodes = installations
        let (mountInfos, mountWarning) = await mounts
        result.mounts = mountInfos

        result.cacheItems = await cachesTask.value
        result.archives = await archivesTask.value
        result.toolchains = await toolchainsTask.value
        result.projectCacheItems = await Task.detached(priority: .utility) {
            ProjectCacheScanner.items(mounts: mountInfos, cachePaths: paths, fileManager: files.value)
        }.value

        let symlinked = CacheItemBuilder.symlinkedDirectories(cachePaths.allClearable, fileManager: fileManager)
        let symlinkWarnings = symlinked.map { "Пропущено, путь проходит через симлинк: \($0.path)" }
        result.warnings = [simulatorWarning, xcodeWarning, mountWarning].compactMap { $0 } + symlinkWarnings
        return result
    }

    /// Archives live at `Archives/<day>/<name>.xcarchive`, so it is the *day folder* — not the
    /// archives root — that has to be trashable for `SafeDeleter` to accept an archive.
    public func makeDeleter(for result: ScanResult) -> SafeDeleter {
        SafeDeleter(
            clearableDirectories: cachePaths.allClearable
                + ProjectCacheScanner.allowedDirectories(mounts: result.mounts, cachePaths: cachePaths),
            trashableParents: [cachePaths.applicationsDirectory, cachePaths.toolchainsDirectory]
                + Array(Set(result.archives.map { $0.url.deletingLastPathComponent() }))
        )
    }

    private static func cacheItems(cachePaths: CachePaths, fileManager: FileManager) -> [CleanupItem] {
        CacheItemBuilder.items(kind: .xcodeCaches, directories: cachePaths.xcodeCaches, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .deviceSupport, directories: cachePaths.deviceSupport, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .simulatorCaches, directories: cachePaths.simulatorCaches, fileManager: fileManager)
    }

    private func scanSimulators() async -> (SimulatorInventory?, String?) {
        do {
            return (try await SimulatorScanner(runner: runner).inventory(), nil)
        } catch {
            return (nil, "Симуляторы недоступны: \(error)")
        }
    }

    private func scanXcodes() async -> ([XcodeInstallation], String?) {
        do {
            let active = try await XcodeInstallationScanner.activeDeveloperDir(runner: runner)
            let applications = cachePaths.applicationsDirectory
            let files = ScannerFileManager(value: fileManager)
            let installations = await Task.detached(priority: .utility) {
                XcodeInstallationScanner.installations(
                    in: applications,
                    activeDeveloperDir: active,
                    fileManager: files.value
                )
            }.value
            return (installations, nil)
        } catch {
            return ([], "xcode-select недоступен: \(error)")
        }
    }

    private func scanMounts() async -> ([ArcMountInfo], String?) {
        do {
            let manager = ArcMountManager(runner: runner, home: cachePaths.home, fileManager: fileManager)
            return (try await manager.list(), nil)
        } catch {
            return ([], "arc недоступен: \(error)")
        }
    }
}
