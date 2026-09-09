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

    /// Compares mount paths the way the guards need to: `arc` may report the main mount with a
    /// trailing slash, a `.` component, a `~` or different case, and every one of those spellings
    /// must still be recognised as the main mount. Deliberately pure string/URL work — resolving
    /// symlinks would touch the filesystem, and a stale FUSE mount path can hang for minutes.
    public static func canonical(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") {
            expanded.removeLast()
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path.lowercased()
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
        let main = Self.canonical(mainMountPath)
        return parsed.sorted { lhs, rhs in
            let lhsIsMain = Self.canonical(lhs.mount) == main
            let rhsIsMain = Self.canonical(rhs.mount) == main
            if lhsIsMain != rhsIsMain {
                return lhsIsMain
            }
            return lhs.mount.localizedStandardCompare(rhs.mount) == .orderedAscending
        }
    }

    /// Sizing the per-mount stores walks tens of gigabytes, so it runs off the cooperative pool and
    /// only for the mounts that can actually be forgotten. The main mount is skipped entirely.
    public func storeSizes(for mounts: [ArcMount]) async -> [String: Int64] {
        let main = Self.canonical(mainMountPath)
        return await withTaskGroup(of: (String, Int64).self) { group in
            for mount in mounts where Self.canonical(mount.mount) != main {
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
        let mainPath = Self.canonical(mainMountPath)
        let main = mounts.first { Self.canonical($0.mount) == mainPath }
        return mounts.map { mount in
            let isMain = Self.canonical(mount.mount) == mainPath
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
        if fileManager.fileExists(atPath: path.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: path.path)
            guard contents.isEmpty else {
                throw ArcMountError.directoryNotEmpty(path.path)
            }
        }
        let mounts = try await mounts()
        let mainPath = Self.canonical(mainMountPath)
        guard let main = mounts.first(where: { Self.canonical($0.mount) == mainPath }) else {
            throw ArcMountError.mainMountNotFound
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        log("mkdir -p \(path.path)")
        let arguments = ["mount", "-m", path.path, "--object-store", main.objectStore, "--override-object-store"]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            removeEmptyMountDirectory(path.path, log: log)
            throw ArcMountError.commandFailed("arc mount", result.stderr)
        }
        return path
    }

    public func unmount(_ mountPath: String, force: Bool, log: @escaping Log) async throws {
        var arguments = ["unmount"]
        if force { arguments.append("--force") }
        arguments.append(mountPath)
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount", result.stderr)
        }
    }

    public func forget(_ mount: ArcMount, log: @escaping Log) async throws {
        guard Self.canonical(mount.mount) != Self.canonical(mainMountPath) else {
            throw ArcMountError.mainMountProtected
        }
        try refuseUnsafePath(mount.mount)
        if mount.isMounted {
            try await unmount(mount.mount, force: false, log: log)
        }
        let arguments = ["unmount", "--forget", mount.mount]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount --forget", result.stderr)
        }
        removeEmptyMountDirectory(mount.mount, log: log)
    }

    /// `--forget` deletes the mount's store, so a malformed `arc` answer such as `/` or `/Users`
    /// must never reach it: only paths strictly below the home directory are accepted.
    private func refuseUnsafePath(_ path: String) throws {
        let homeComponents = URL(fileURLWithPath: Self.canonical(home.path)).pathComponents
        let pathComponents = URL(fileURLWithPath: Self.canonical(path)).pathComponents
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
