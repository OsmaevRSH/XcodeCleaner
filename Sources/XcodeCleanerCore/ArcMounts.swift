import Foundation

public struct ArcMount: Sendable, Equatable, Identifiable, Decodable, Hashable {
    public enum Status: String, Sendable, Decodable, Hashable {
        case mounted
        case unmounted
    }

    public let status: Status
    public let mount: String
    public let store: String
    public let objectStore: String

    public init(status: Status, mount: String, store: String, objectStore: String) {
        self.status = status
        self.mount = mount
        self.store = store
        self.objectStore = objectStore
    }

    enum CodingKeys: String, CodingKey {
        case status
        case mount
        case store
        case objectStore = "object-store"
    }

    public var id: String { mount }
    public var name: String { URL(fileURLWithPath: mount).lastPathComponent }
    public var isMounted: Bool { status == .mounted }

    public static func parse(_ data: Data) throws -> [ArcMount] {
        try JSONDecoder().decode([ArcMount].self, from: data)
    }
}

public struct ArcMountInfo: Sendable, Equatable, Identifiable, Hashable {
    public let mount: ArcMount
    public let storeSizeBytes: Int64?
    public let isMain: Bool
    public let sharesMainObjectStore: Bool

    public init(mount: ArcMount, storeSizeBytes: Int64?, isMain: Bool, sharesMainObjectStore: Bool) {
        self.mount = mount
        self.storeSizeBytes = storeSizeBytes
        self.isMain = isMain
        self.sharesMainObjectStore = sharesMainObjectStore
    }

    public var id: String { mount.id }
}

public enum ArcMountError: Error, Equatable, Sendable, LocalizedError {
    case invalidName(String)
    case directoryNotEmpty(String)
    case mainMountNotFound
    case mainMountProtected
    case refusedPath(String)
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name): "Недопустимое имя маунта: \"\(name)\""
        case let .directoryNotEmpty(path): "Папка уже существует и не пуста: \(path)"
        case .mainMountNotFound: "Основной маунт ~/arcadia не найден"
        case .mainMountProtected: "Основной маунт ~/arcadia удалить нельзя"
        case let .refusedPath(path): "Небезопасный путь маунта, удаление отклонено: \(path)"
        case let .commandFailed(command, stderr): "\(command) завершилась с ошибкой: \(stderr)"
        }
    }
}

public struct ArcMountManager: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let runner: any CommandRunning
    private let home: URL
    // Any injected `FileManager` must be thread-safe (the shared default instance is); it is only
    // read.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(runner: any CommandRunning, home: URL, fileManager: FileManager = .default) {
        self.runner = runner
        self.home = home.standardizedFileURL
        self.fileManager = fileManager
    }

    public var mainMountPath: String { home.appendingPathComponent("arcadia").path }

    /// The spelling handed back to `arc` and `rmdir`: `arc` may report a mount with a trailing
    /// slash, a `.` component or a `~`, and all of those have to be resolved before the path is
    /// used as an argument. Tilde expansion is relative to this manager's `home` rather than the
    /// process environment, so an injected home stays authoritative. Deliberately pure string/URL
    /// work — resolving symlinks would touch the filesystem, and a stale FUSE mount path can hang
    /// for minutes.
    public func normalizedPath(_ path: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = home.path
        } else if expanded.hasPrefix("~/") {
            expanded = home.path + expanded.dropFirst(1)
        }
        while expanded.count > 1, expanded.hasSuffix("/") {
            expanded.removeLast()
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// The spelling the guards compare: normalised and lowercased, because APFS is usually
    /// case-insensitive and `/Users/Tester/arcadia` must still be recognised as the main mount.
    /// Never passed to a command — a lowercased path can name a different file on a case-sensitive
    /// volume.
    public func comparablePath(_ path: String) -> String {
        normalizedPath(path).lowercased()
    }

    public func mounts() async throws -> [ArcMount] {
        let result = try await runner.run("arc", ["mount", "--list", "--json"], currentDirectory: home, onOutputLine: nil)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc mount --list", result.stderr)
        }
        let parsed: [ArcMount]
        do {
            parsed = try ArcMount.parse(Data(result.stdout.utf8))
        } catch let error as DecodingError {
            throw ArcMountError.commandFailed("arc mount --list", "\(error)")
        }
        let main = comparablePath(mainMountPath)
        return parsed.sorted { lhs, rhs in
            let lhsIsMain = comparablePath(lhs.mount) == main
            let rhsIsMain = comparablePath(rhs.mount) == main
            if lhsIsMain != rhsIsMain {
                return lhsIsMain
            }
            return lhs.mount.compare(rhs.mount, options: .numeric) == .orderedAscending
        }
    }

    /// Sizing the per-mount stores walks tens of gigabytes, so each store is walked in its own
    /// child task at utility priority and only for the mounts that can actually be forgotten; the
    /// main mount is skipped entirely. Child tasks — unlike detached ones — inherit cancellation,
    /// which is what lets `DirectorySizer` abandon a walk in progress.
    public func storeSizes(for mounts: [ArcMount]) async -> [String: Int64] {
        let main = comparablePath(mainMountPath)
        return await withTaskGroup(of: (String, Int64).self) { group in
            for mount in mounts where comparablePath(mount.mount) != main {
                let key = mount.mount
                let store = mount.store
                // A freshly created `FileManager` is owned by the child task alone, so nothing has
                // to cross an isolation boundary and `group.cancelAll()` reaches the walk itself.
                group.addTask(priority: .utility) {
                    (key, DirectorySizer.size(of: URL(fileURLWithPath: store), fileManager: FileManager()))
                }
            }
            var sizes: [String: Int64] = [:]
            for await (key, size) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                sizes[key] = size
            }
            return sizes
        }
    }

    public func list() async throws -> [ArcMountInfo] {
        let mounts = try await mounts()
        let sizes = await storeSizes(for: mounts)
        let mainPath = comparablePath(mainMountPath)
        let main = mounts.first { comparablePath($0.mount) == mainPath }
        return mounts.map { mount in
            let isMain = comparablePath(mount.mount) == mainPath
            return ArcMountInfo(
                mount: mount,
                storeSizeBytes: isMain ? nil : sizes[mount.mount],
                isMain: isMain,
                sharesMainObjectStore: main.map { $0.objectStore == mount.objectStore } ?? false
            )
        }
    }

    /// The name is only ever a path *suffix* after the fixed `arcadia_` prefix, so a name starting
    /// with `-` can never turn into an option when the path is passed to `arc mount -m`.
    public func mountPath(forName name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/ \t\n").union(.controlCharacters)
        guard trimmed.isEmpty == false,
              trimmed != "..",
              trimmed.rangeOfCharacter(from: forbidden) == nil
        else {
            throw ArcMountError.invalidName(name)
        }
        return home.appendingPathComponent("arcadia_\(trimmed)")
    }

    @discardableResult
    public func mountNew(name: String, log: @escaping Log) async throws -> URL {
        let path = try mountPath(forName: name)
        let existedBefore = fileManager.fileExists(atPath: path.path)
        if existedBefore {
            let contents = try fileManager.contentsOfDirectory(atPath: path.path)
            guard contents.isEmpty else {
                throw ArcMountError.directoryNotEmpty(path.path)
            }
        }
        let mounts = try await mounts()
        let mainPath = comparablePath(mainMountPath)
        guard let main = mounts.first(where: { comparablePath($0.mount) == mainPath }) else {
            throw ArcMountError.mainMountNotFound
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        if existedBefore == false {
            log("mkdir -p \(path.path)")
        }
        let arguments = ["mount", "-m", path.path, "--object-store", main.objectStore, "--override-object-store"]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            // A directory that was already there is the user's, not ours to clean up.
            if existedBefore == false {
                removeEmptyMountDirectory(path.path, log: log)
            }
            throw ArcMountError.commandFailed("arc mount", result.stderr)
        }
        return path
    }

    public func unmount(_ mountPath: String, force: Bool, log: @escaping Log) async throws {
        try refuseUnsafePath(mountPath)
        var arguments = ["unmount"]
        if force { arguments.append("--force") }
        arguments.append(normalizedPath(mountPath))
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount", result.stderr)
        }
    }

    public func forget(_ mount: ArcMount, log: @escaping Log) async throws {
        guard comparablePath(mount.mount) != comparablePath(mainMountPath) else {
            throw ArcMountError.mainMountProtected
        }
        try refuseUnsafePath(mount.mount)
        let path = normalizedPath(mount.mount)
        if mount.isMounted {
            try await unmount(path, force: false, log: log)
        }
        let arguments = ["unmount", "--forget", path]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount --forget", result.stderr)
        }
        removeEmptyMountDirectory(path, log: log)
    }

    /// `--forget` deletes the mount's store and `unmount` tears down a live FUSE mount, so a
    /// malformed `arc` answer such as `/` or `/Users` must never reach either: only paths strictly
    /// below the home directory are accepted. The original spelling is reported back so the user
    /// sees the path they were shown.
    private func refuseUnsafePath(_ path: String) throws {
        let homeComponents = URL(fileURLWithPath: comparablePath(home.path)).pathComponents
        let pathComponents = URL(fileURLWithPath: comparablePath(path)).pathComponents
        guard pathComponents.count > homeComponents.count,
              Array(pathComponents.prefix(homeComponents.count)) == homeComponents
        else {
            throw ArcMountError.refusedPath(path)
        }
    }

    /// `rmdir(2)` removes the directory only when it is empty, so there is no window between
    /// checking and deleting in which the mount could be repopulated (or replaced by a symlink)
    /// and then removed recursively.
    private func removeEmptyMountDirectory(_ path: String, log: Log) {
        guard rmdir(path) != 0 else {
            log("rmdir \(path)")
            return
        }
        let code = errno
        switch code {
        case ENOTEMPTY, EEXIST:
            log("Папка \(path) не пуста, оставлена на месте")
        case ENOENT:
            return
        default:
            let message = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
            log("Не удалось удалить папку \(path): \(message)")
        }
    }
}
