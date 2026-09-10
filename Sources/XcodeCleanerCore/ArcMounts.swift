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
    /// Nil until somebody measures it: `ArcMountManager.list()` leaves it empty on purpose.
    public let storeSizeBytes: Int64?
    public let isMain: Bool
    public let sharesMainObjectStore: Bool
    public let lastUsedAt: Date?

    public init(
        mount: ArcMount,
        storeSizeBytes: Int64?,
        isMain: Bool,
        sharesMainObjectStore: Bool,
        lastUsedAt: Date?
    ) {
        self.mount = mount
        self.storeSizeBytes = storeSizeBytes
        self.isMain = isMain
        self.sharesMainObjectStore = sharesMainObjectStore
        self.lastUsedAt = lastUsedAt
    }

    public var id: String { mount.id }
}

public enum ArcMountError: Error, Equatable, Sendable, LocalizedError {
    case mainMountProtected
    case refusedPath(String)
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .mainMountProtected: "Основной маунт ~/arcadia удалить нельзя"
        case let .refusedPath(path): "Небезопасный путь, удаление отклонено: \(path)"
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

    /// The only directory arc keeps per-mount stores in, and therefore the only directory this
    /// manager ever deletes recursively. Containing a path here is a check on its *spelling*, not
    /// on where it leads — see `refuseUnsafeStore(_:log:)` for the rest of the guard.
    public var storesRootPath: String { home.appendingPathComponent(".arc/stores").path }

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

    /// Arc rewrites `<store>/.arc` whenever the mount is actually used — a checkout or a commit
    /// moves it — while the store root's own mtime stays at the moment the store was created. The
    /// metadata directory is therefore the honest answer to "when was this mount last touched"; the
    /// root is only a fallback for a store arc has not populated yet.
    ///
    /// The store is spelled the way `arc` reported it, which may be a `~` path — and
    /// `URL(fileURLWithPath:)` would resolve that against the process's current directory instead
    /// of this manager's home — so it goes through the same normalisation as every other path here.
    public func lastUsed(ofStore store: String) -> Date? {
        let root = URL(fileURLWithPath: normalizedPath(store))
        return Self.modificationDate(of: root.appendingPathComponent(".arc").path, fileManager: fileManager)
            ?? Self.modificationDate(of: root.path, fileManager: fileManager)
    }

    /// Deliberately measures nothing: one `arc mount --list` plus one `stat` per store, so the list
    /// appears at once. `storeSizeBytes` stays nil until a caller fills it in — for the app that is
    /// `Scanner.measureSizes(for:onSize:)`.
    public func list() async throws -> [ArcMountInfo] {
        let mounts = try await mounts()
        let mainPath = comparablePath(mainMountPath)
        let main = mounts.first { comparablePath($0.mount) == mainPath }
        return mounts.map { mount in
            ArcMountInfo(
                mount: mount,
                storeSizeBytes: nil,
                isMain: comparablePath(mount.mount) == mainPath,
                sharesMainObjectStore: main.map { $0.objectStore == mount.objectStore } ?? false,
                lastUsedAt: lastUsed(ofStore: mount.store)
            )
        }
    }

    public func unmount(_ mountPath: String, force: Bool, log: @escaping Log) async throws {
        try refuseUnsafePath(mountPath)
        let result = try await runUnmount(normalizedPath(mountPath), force: force, log: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount", Self.output(of: result))
        }
    }

    /// Removes everything the mount owns: the live FUSE mount, arc's registry entry, the per-mount
    /// store and the empty mount directory.
    ///
    /// `arc` is best-effort here. It exits 1 for a repository that is already unmounted and again
    /// for a path it no longer recognises, and neither answer means the user's intent — "delete
    /// this mount and everything behind it" — is out of reach: the store is still there to delete.
    /// A run is only reported as a failure when it neither convinced `arc` nor left the machine in
    /// the state the user asked for.
    ///
    /// - Parameter knownStoreSize: the size the caller already measured for this store, logged as
    ///   the space freed. Nothing is measured here: this is the destructive path, and walking a
    ///   multi-gigabyte store again to print a number the UI has already shown would block the
    ///   removal for as long as the scan did.
    public func remove(_ mount: ArcMount, knownStoreSize: Int64?, log: @escaping Log) async throws {
        guard comparablePath(mount.mount) != comparablePath(mainMountPath) else {
            throw ArcMountError.mainMountProtected
        }
        try refuseUnsafePath(mount.mount)
        try refuseUnsafeStore(mount.store, log: log)
        let path = normalizedPath(mount.mount)

        if mount.isMounted {
            let result = try await runUnmount(path, force: false, log: log)
            if result.succeeded == false {
                let output = Self.output(of: result)
                guard output.lowercased().contains(Self.alreadyUnmountedMessage) else {
                    throw ArcMountError.commandFailed("arc unmount", output)
                }
                log("Маунт \(path) уже размонтирован, продолжаем")
            }
        }

        let arguments = ["unmount", "--forget", path]
        log("arc \(arguments.joined(separator: " "))")
        let forgetResult = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        if forgetResult.succeeded == false {
            log("arc не забыла маунт \(path), удаляем стор сами")
        }

        let storeRemoval = try removeStore(mount.store, knownSize: knownStoreSize, log: log)
        removeEmptyMountDirectory(path, log: log)

        if forgetResult.succeeded == false, storeRemoval != .removed {
            // A repeat of a stale list is not a failure: `arc` no longer knows the mount, the store
            // is already gone and so is the mount directory, which is exactly what was asked for.
            guard storeRemoval == .absent, fileManager.fileExists(atPath: path) == false else {
                throw ArcMountError.commandFailed("arc unmount --forget", Self.output(of: forgetResult))
            }
            log("Маунт \(path) и его стор уже удалены, удалять нечего")
        }
    }

    /// Removes the mount without reporting how much space its store took.
    public func remove(_ mount: ArcMount, log: @escaping Log) async throws {
        try await remove(mount, knownStoreSize: nil, log: log)
    }

    private func runUnmount(_ path: String, force: Bool, log: @escaping Log) async throws -> CommandResult {
        var arguments = ["unmount"]
        if force { arguments.append("--force") }
        arguments.append(path)
        log("arc \(arguments.joined(separator: " "))")
        return try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
    }

    /// The exact sentence `arc` prints for a mount that is no longer live. Matched in full because
    /// anything shorter also matches a hint like "if the repository is already unmounted, use
    /// --forget" — which arrives *with* a genuine failure such as a busy mount, and swallowing
    /// that would point the store deletion at a mount the user is still working in.
    private static let alreadyUnmountedMessage = "repository seems to be already unmounted"

    /// Whether the store directory is gone, and whether this call is the reason.
    private enum StoreRemoval {
        case removed
        case absent
        case failed
    }

    /// The fallback for a store that `arc unmount --forget` left behind: it is gigabytes of this
    /// mount's own objects and the user asked for it to go. `remove(_:knownStoreSize:log:)` has
    /// already refused the main mount and vetted this path once, but two `arc` invocations run in
    /// between — so the guard is re-run here rather than assumed, and it is the one immediately
    /// before `removeItem` that actually protects the delete.
    private func removeStore(_ store: String, knownSize: Int64?, log: Log) throws -> StoreRemoval {
        let path = normalizedPath(store)
        guard fileManager.fileExists(atPath: path) else { return .absent }
        try refuseUnsafeStore(store, log: log)
        do {
            try fileManager.removeItem(atPath: path)
            let freed = knownSize.map { ", освобождено \(ByteFormatting.string($0))" } ?? ""
            log("Удалена папка стора \(path)\(freed)")
            return .removed
        } catch {
            log("Не удалось удалить папку стора \(path): \(error.localizedDescription)")
            return .failed
        }
    }

    /// Refuses any store the recursive delete must never be aimed at. Runs once before `arc` is
    /// asked to do anything — so a malformed `store` field cannot leave the mount torn down but not
    /// removed — and again immediately before the delete itself.
    ///
    /// Confinement to `~/.arc/stores/` — the only place arc keeps per-mount stores — is purely
    /// lexical: `standardizedFileURL` resolves `..` but never a symlink, so `<stores>/link/victim`
    /// satisfies it while `removeItem` walks straight out of the stores root. A store that is
    /// itself a symlink is refused for the opposite reason: deleting it reaches the tree behind the
    /// link instead of the store, and even when it only unlinks, nothing is actually freed. Both
    /// are settled against the filesystem, the same way `SafeDeleter` does it.
    ///
    /// A store that is not on disk at all is nothing to aim at and no reason to refuse the removal:
    /// `arc unmount --forget` may still have work to do, and `removeStore(_:knownSize:log:)`
    /// reports the store as absent afterwards.
    private func refuseUnsafeStore(_ store: String, log: Log) throws {
        let path = normalizedPath(store)
        guard let type = Self.fileType(of: path, fileManager: fileManager) else { return }
        let url = URL(fileURLWithPath: path)
        let reason: String
        if isStrictlyInside(path, of: storesRootPath) == false {
            reason = "лежит вне \(storesRootPath)"
        } else if url.resolvingSymlinksInPath().path != url.standardizedFileURL.path {
            reason = "ведёт через симлинк"
        } else if type == .typeSymbolicLink {
            reason = "сам является симлинком"
        } else {
            return
        }
        log("Стор \(path) \(reason), удаление отклонено")
        throw ArcMountError.refusedPath(store)
    }

    /// `arc` puts its diagnostics on either stream depending on the subcommand, so both are read
    /// when a failure is classified and when it is reported back.
    private static func output(of result: CommandResult) -> String {
        [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    private static func modificationDate(of path: String, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Nil when nothing is there. `attributesOfItem(atPath:)` follows the intermediate components
    /// but not the last one, so a symlink reports itself rather than what it points at.
    private static func fileType(of path: String, fileManager: FileManager) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    /// `--forget` deletes the mount's store and `unmount` tears down a live FUSE mount, so a
    /// malformed `arc` answer such as `/` or `/Users` must never reach either: only paths strictly
    /// below the home directory are accepted. The original spelling is reported back so the user
    /// sees the path they were shown.
    private func refuseUnsafePath(_ path: String) throws {
        guard isStrictlyInside(path, of: home.path) else {
            throw ArcMountError.refusedPath(path)
        }
    }

    private func isStrictlyInside(_ path: String, of root: String) -> Bool {
        let rootComponents = URL(fileURLWithPath: comparablePath(root)).pathComponents
        let pathComponents = URL(fileURLWithPath: comparablePath(path)).pathComponents
        return pathComponents.count > rootComponents.count
            && Array(pathComponents.prefix(rootComponents.count)) == rootComponents
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
