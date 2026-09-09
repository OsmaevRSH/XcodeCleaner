import Foundation

public enum CleanupKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case xcodeCaches
    case deviceSupport
    case simulatorCaches
    case simulators
    case archives
    case xcodeApps
    case toolchains
    case projectCaches

    public var id: String { rawValue }

    public static let executionOrder: [CleanupKind] = [
        .xcodeCaches, .deviceSupport, .simulatorCaches, .simulators,
        .archives, .xcodeApps, .toolchains, .projectCaches,
    ]

    public var title: String {
        switch self {
        case .xcodeCaches: "Кэши Xcode"
        case .deviceSupport: "DeviceSupport"
        case .simulatorCaches: "CoreSimulator и SwiftPM"
        case .simulators: "Симуляторы"
        case .archives: "Archives"
        case .xcodeApps: "Старые Xcode"
        case .toolchains: "Toolchains"
        case .projectCaches: "Проектные кэши"
        }
    }
}

public enum SimulatorMode: String, CaseIterable, Sendable, Hashable, Identifiable {
    case deleteUnavailable
    case eraseAll
    case deleteAll
    case deleteAllAndRuntimes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deleteUnavailable: "Удалить только недоступные"
        case .eraseAll: "Стереть данные всех симуляторов"
        case .deleteAll: "Удалить все симуляторы"
        case .deleteAllAndRuntimes: "Удалить все симуляторы и runtimes"
        }
    }

    public var isDestructive: Bool { self != .deleteUnavailable }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case clearContents(URL)
        case trash(URL)
        case simulators(SimulatorMode)
    }

    public let id: String
    public let kind: CleanupKind
    public let title: String
    public let subtitle: String
    public let action: Action
    public let sizeBytes: Int64?
    public let isDestructive: Bool

    public init(
        id: String,
        kind: CleanupKind,
        title: String,
        subtitle: String,
        action: Action,
        sizeBytes: Int64?,
        isDestructive: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.sizeBytes = sizeBytes
        self.isDestructive = isDestructive
    }
}

public struct CachePaths: Sendable {
    public let home: URL
    public let applicationsDirectory: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications")
    ) {
        self.home = home.standardizedFileURL
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
    }

    public static let projectCacheSubpaths = [
        "mobile/saft/ios/Tuist/.build",
        "mobile/saft/ios/Derived",
        "mobile/saft/ios/DerivedData",
    ]

    private func library(_ path: String) -> URL {
        home.appendingPathComponent("Library").appendingPathComponent(path)
    }

    public var xcodeCaches: [URL] {
        [
            library("Developer/Xcode/DerivedData"),
            library("Developer/Xcode/DocumentationCache"),
            library("Developer/Xcode/UserData/Previews"),
            library("Caches/com.apple.dt.Xcode"),
        ]
    }

    public var deviceSupport: [URL] {
        ["iOS", "watchOS", "tvOS", "visionOS"].map {
            library("Developer/Xcode/\($0) DeviceSupport")
        }
    }

    public var simulatorCaches: [URL] {
        [
            library("Developer/CoreSimulator/Caches"),
            library("Caches/com.apple.CoreSimulator"),
            library("Caches/org.swift.swiftpm"),
            library("Logs/CoreSimulator"),
        ]
    }

    public var globalProjectCaches: [URL] {
        [home.appendingPathComponent(".cache/tuist")]
    }

    public var archivesDirectory: URL { library("Developer/Xcode/Archives") }
    public var toolchainsDirectory: URL { library("Developer/Toolchains") }
    public var arcStoresDirectory: URL { home.appendingPathComponent(".arc/stores") }
    public var mainArcadiaMount: URL { home.appendingPathComponent("arcadia") }

    public var allClearable: [URL] {
        xcodeCaches + deviceSupport + simulatorCaches + globalProjectCaches
    }

    public func projectCacheDirectories(inMount mount: URL) -> [URL] {
        Self.projectCacheSubpaths.map { mount.appendingPathComponent($0) }
    }
}

public enum CacheItemBuilder {
    public static func items(
        kind: CleanupKind,
        directories: [URL],
        fileManager: FileManager = .default
    ) -> [CleanupItem] {
        directories.compactMap { directory in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path
            else {
                return nil
            }
            return CleanupItem(
                id: directory.path,
                kind: kind,
                title: directory.lastPathComponent,
                subtitle: directory.path,
                action: .clearContents(directory),
                sizeBytes: DirectorySizer.size(of: directory, fileManager: fileManager),
                isDestructive: false
            )
        }
    }

    /// The directories `items` silently drops because they are symlinks or sit behind one, so a
    /// scanner can surface them as warnings instead of leaving the user wondering where a cache
    /// they can see went.
    public static func symlinkedDirectories(
        _ directories: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        directories.filter { directory in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return false
            }
            return directory.resolvingSymlinksInPath().path != directory.standardizedFileURL.path
        }
    }
}
