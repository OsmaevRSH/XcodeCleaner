import Foundation

public struct DeletionFailure: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum SafeDeleterError: Error, Equatable, Sendable, LocalizedError {
    case notAllowed(String)
    case notADirectory(String)
    case isSymlink(String)
    case cannotInspect(String, String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let path):
            "Путь не входит в allowlist: \(path)"
        case .notADirectory(let path):
            "Путь не является директорией: \(path)"
        case .isSymlink(let path):
            "Путь является символической ссылкой или ведёт через неё: \(path)"
        case .cannotInspect(let path, let reason):
            "Не удалось прочитать атрибуты пути \(path): \(reason)"
        }
    }
}

public struct SafeDeleter: Sendable {
    public static let trashableExtensions: Set<String> = ["xcarchive", "app", "xctoolchain"]

    public let clearableDirectories: Set<String>
    public let trashableParents: Set<String>

    public init(clearableDirectories: [URL], trashableParents: [URL]) {
        self.clearableDirectories = Set(clearableDirectories.map(Self.normalize))
        self.trashableParents = Set(trashableParents.map(Self.normalize))
    }

    public func clearContents(
        of directory: URL,
        fileManager: FileManager = .default
    ) throws -> [DeletionFailure] {
        let target = directory.standardizedFileURL
        guard clearableDirectories.contains(target.path) else {
            throw SafeDeleterError.notAllowed(directory.path)
        }
        try Self.rejectSymlinkTraversal(target, reporting: directory.path)
        let attributes = try Self.attributes(atPath: target.path, fileManager: fileManager)
        if attributes.type == .typeSymbolicLink {
            throw SafeDeleterError.isSymlink(directory.path)
        }
        guard attributes.type == .typeDirectory else {
            throw SafeDeleterError.notADirectory(directory.path)
        }

        var failures: [DeletionFailure] = []
        let children = try fileManager.contentsOfDirectory(atPath: target.path)
        for name in children {
            let child = target.appendingPathComponent(name)
            do {
                let childAttributes = try Self.attributes(atPath: child.path, fileManager: fileManager)
                if childAttributes.type != .typeSymbolicLink,
                   childAttributes.device != attributes.device {
                    failures.append(DeletionFailure(path: child.path, reason: "nested volume, skipped"))
                    continue
                }
                try fileManager.removeItem(at: child)
            } catch {
                failures.append(DeletionFailure(path: child.path, reason: error.localizedDescription))
            }
        }
        return failures
    }

    public func trash(_ url: URL, fileManager: FileManager = .default) throws {
        let target = url.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard trashableParents.contains(parent.path),
              Self.trashableExtensions.contains(target.pathExtension.lowercased())
        else {
            throw SafeDeleterError.notAllowed(url.path)
        }
        // Foundation hands back a path it could not resolve unchanged, so a check anchored on the
        // item itself silently passes whenever the leaf is missing. The parent is allowlisted and
        // therefore exists, which makes it the reliable anchor.
        try Self.rejectSymlinkTraversal(parent, reporting: url.path)
        let attributes = try Self.attributes(atPath: target.path, fileManager: fileManager)
        guard attributes.type != .typeSymbolicLink else {
            throw SafeDeleterError.isSymlink(url.path)
        }
        try fileManager.trashItem(at: target, resultingItemURL: nil)
    }

    /// `lstat` only refuses to follow the *last* path component, so an allowlisted path whose
    /// ancestor is a symlink would still resolve to — and wipe — somewhere else entirely.
    private static func rejectSymlinkTraversal(_ url: URL, reporting path: String) throws {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw SafeDeleterError.isSymlink(path)
        }
    }

    private struct ItemAttributes {
        let type: FileAttributeType
        let device: Int
    }

    private static func attributes(atPath path: String, fileManager: FileManager) throws -> ItemAttributes {
        let raw: [FileAttributeKey: Any]
        do {
            raw = try fileManager.attributesOfItem(atPath: path)
        } catch {
            throw SafeDeleterError.cannotInspect(path, error.localizedDescription)
        }
        let type = (raw[.type] as? FileAttributeType) ?? .typeUnknown
        guard let device = raw[.systemNumber] as? Int else {
            throw SafeDeleterError.cannotInspect(path, "атрибут systemNumber недоступен")
        }
        return ItemAttributes(type: type, device: device)
    }

    private static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
