import Foundation

public struct DeletionFailure: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum SafeDeleterError: Error, Equatable, Sendable {
    case notAllowed(String)
    case notADirectory(String)
    case isSymlink(String)
    case cannotInspect(String)
}

public struct SafeDeleter: Sendable {
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
        let path = Self.normalize(directory)
        guard clearableDirectories.contains(path) else {
            throw SafeDeleterError.notAllowed(directory.path)
        }
        let attributes = try Self.attributes(atPath: directory.path, fileManager: fileManager)
        if attributes.type == .typeSymbolicLink {
            throw SafeDeleterError.isSymlink(directory.path)
        }
        guard attributes.type == .typeDirectory else {
            throw SafeDeleterError.notADirectory(directory.path)
        }

        var failures: [DeletionFailure] = []
        let children = try fileManager.contentsOfDirectory(atPath: directory.path)
        for name in children {
            let child = directory.appendingPathComponent(name)
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
        let parent = Self.normalize(url.deletingLastPathComponent())
        guard trashableParents.contains(parent) else {
            throw SafeDeleterError.notAllowed(url.path)
        }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
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
            throw SafeDeleterError.cannotInspect(path)
        }
        let type = (raw[.type] as? FileAttributeType) ?? .typeUnknown
        let device = (raw[.systemNumber] as? Int) ?? -1
        return ItemAttributes(type: type, device: device)
    }

    private static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
