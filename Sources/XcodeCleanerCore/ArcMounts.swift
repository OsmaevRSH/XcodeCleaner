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

    public var id: String { mount.id }
}

public enum ArcMountError: Error, Equatable, Sendable {
    case invalidName(String)
    case directoryNotEmpty(String)
    case mainMountNotFound
    case mainMountProtected
    case commandFailed(String, String)
}

public struct ArcMountManager: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let runner: any CommandRunning
    private let home: URL
    private nonisolated(unsafe) let fileManager: FileManager

    public init(runner: any CommandRunning, home: URL, fileManager: FileManager = .default) {
        self.runner = runner
        self.home = home.standardizedFileURL
        self.fileManager = fileManager
    }

    public var mainMountPath: String { home.appendingPathComponent("arcadia").path }

    public func list() async throws -> [ArcMountInfo] {
        let result = try await runner.run("arc", ["mount", "--list", "--json"], currentDirectory: home, onOutputLine: nil)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc mount --list", result.stderr)
        }
        let mounts = try ArcMount.parse(Data(result.stdout.utf8))
        let main = mounts.first { $0.mount == mainMountPath }
        return mounts
            .sorted { $0.mount < $1.mount }
            .map { mount in
                let isMain = mount.mount == mainMountPath
                return ArcMountInfo(
                    mount: mount,
                    storeSizeBytes: isMain ? nil : DirectorySizer.size(of: URL(fileURLWithPath: mount.store), fileManager: fileManager),
                    isMain: isMain,
                    sharesMainObjectStore: main.map { $0.objectStore == mount.objectStore } ?? false
                )
            }
    }

    public func mountPath(forName name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/ \t\n")
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
        let infos = try await list()
        guard let main = infos.first(where: \.isMain) else {
            throw ArcMountError.mainMountNotFound
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        log("mkdir -p \(path.path)")
        let arguments = ["mount", "-m", path.path, "--object-store", main.mount.objectStore, "--override-object-store"]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
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
        guard mount.mount != mainMountPath else {
            throw ArcMountError.mainMountProtected
        }
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

    private func removeEmptyMountDirectory(_ path: String, log: Log) {
        guard fileManager.fileExists(atPath: path) else { return }
        let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? ["?"]
        guard contents.isEmpty else {
            log("Папка \(path) не пуста, оставлена на месте")
            return
        }
        do {
            try fileManager.removeItem(atPath: path)
            log("rmdir \(path)")
        } catch {
            log("Не удалось удалить пустую папку \(path): \(error.localizedDescription)")
        }
    }
}
