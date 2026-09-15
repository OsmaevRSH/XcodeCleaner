import Foundation

/// The only distinction the user has to make before pressing the button: whether the thing comes
/// back by itself.
public enum CleanupGroup: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Regenerates by itself; the cost of deleting it is time, not data.
    case safe
    /// Does not come back on its own; deleting it means downloading or rebuilding it deliberately.
    case attention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .safe: "Восстановится само"
        case .attention: "Не восстановится автоматически"
        }
    }
}

public enum CleanupKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case xcodeCaches
    case previews
    case deviceSupport
    case simulatorCaches
    case simulators
    case archives
    case xcodeApps
    case toolchains
    case projectCaches

    public var id: String { rawValue }

    public static let executionOrder: [CleanupKind] = [
        .xcodeCaches, .previews, .deviceSupport, .simulatorCaches, .simulators,
        .archives, .xcodeApps, .toolchains, .projectCaches,
    ]

    public var title: String {
        switch self {
        case .xcodeCaches: "Кэши сборки"
        case .previews: "Превью и документация"
        case .deviceSupport: "DeviceSupport"
        case .simulatorCaches: "CoreSimulator и SwiftPM"
        case .simulators: "Симуляторы"
        case .archives: "Archives"
        case .xcodeApps: "Старые Xcode"
        case .toolchains: "Toolchains"
        case .projectCaches: "Проектные кэши"
        }
    }

    /// What the user loses, in one line. Never a path: the paths are the item subtitles, and a
    /// category header full of them is what made the list unreadable.
    public var subtitle: String {
        switch self {
        case .xcodeCaches: "DerivedData и индексы. Первая сборка станет дольше"
        case .previews: "Кэш SwiftUI Previews и документации Xcode"
        case .deviceSupport: "Символы iOS, watchOS и tvOS. Скачаются при подключении устройства"
        case .simulatorCaches: "Кэши CoreSimulator и SwiftPM, логи симуляторов"
        case .simulators: "Устройства симуляторов и скачанные runtimes"
        case .archives: "Сборки .xcarchive и dSYM. Уйдут в Корзину"
        case .xcodeApps: "Неиспользуемые версии Xcode. Уйдут в Корзину"
        case .toolchains: "Дополнительные Swift toolchains. Уйдут в Корзину"
        case .projectCaches: "Tuist и SwiftPM внутри проектов. Пересоберутся"
        }
    }

    /// Simulators stay `.safe` here because only some of the modes destroy anything; the mode the
    /// user picked carries `isDestructive` on the item itself.
    public var group: CleanupGroup {
        switch self {
        case .archives, .xcodeApps, .toolchains: .attention
        case .xcodeCaches, .previews, .deviceSupport, .simulatorCaches, .simulators, .projectCaches: .safe
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

/// A directory to clean plus the name it is shown under. The name is carried rather than derived
/// from the path: several mounts contribute a `.build` each, and a row reading `.build` says
/// nothing about which one it belongs to.
public struct CacheDirectory: Sendable, Hashable {
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

public struct CachePaths: Sendable {
    public let home: URL
    public let applicationsDirectory: URL
    /// Where inside an Arcadia mount the projects live. Everything about project caches — the fixed
    /// Tuist outputs and the `.build` directories the walk looks for — is confined to these, because
    /// a mount is the whole monorepo and walking all of it is not something a cleanup tool may do.
    public let projectSearchRoots: [String]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications"),
        projectSearchRoots: [String] = CachePaths.defaultProjectSearchRoots
    ) {
        self.home = home.standardizedFileURL
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
        self.projectSearchRoots = projectSearchRoots
    }

    public static let defaultProjectSearchRoots = ["mobile/saft/ios", "mobile/music/ios"]

    /// The project caches that sit at a known place: Tuist writes both next to the project, and
    /// either may be missing at the moment of a scan and appear before the cleanup runs — so they
    /// are offered by path rather than found. `.build` is deliberately absent: `swift build` leaves
    /// one next to every `Package.swift`, and only `ProjectCacheScanner.discoverBuildDirectories`
    /// knows where those are.
    public var projectCacheSubpaths: [String] {
        projectSearchRoots.flatMap { ["\($0)/Derived", "\($0)/DerivedData"] }
    }

    private func library(_ path: String) -> URL {
        home.appendingPathComponent("Library").appendingPathComponent(path)
    }

    private func library(_ path: String, named title: String) -> CacheDirectory {
        CacheDirectory(url: library(path), title: title)
    }

    public var xcodeCaches: [CacheDirectory] {
        [
            library("Developer/Xcode/DerivedData", named: "DerivedData"),
            library("Caches/com.apple.dt.Xcode", named: "Кэш Xcode"),
        ]
    }

    public var previews: [CacheDirectory] {
        [
            library("Developer/Xcode/UserData/Previews", named: "SwiftUI Previews"),
            library("Developer/Xcode/DocumentationCache", named: "Кэш документации"),
        ]
    }

    public var deviceSupport: [CacheDirectory] {
        ["iOS", "watchOS", "tvOS", "visionOS"].map {
            library("Developer/Xcode/\($0) DeviceSupport", named: $0)
        }
    }

    /// Two of these are CoreSimulator's and neither is named after it on disk, so the titles say
    /// which is which instead of leaving the user with two rows about the same thing.
    public var simulatorCaches: [CacheDirectory] {
        [
            library("Developer/CoreSimulator/Caches", named: "CoreSimulator, кэш образов"),
            library("Caches/com.apple.CoreSimulator", named: "CoreSimulator, системный кэш"),
            library("Caches/org.swift.swiftpm", named: "SwiftPM, кэш пакетов"),
            library("Logs/CoreSimulator", named: "Логи симуляторов"),
        ]
    }

    public var globalProjectCaches: [CacheDirectory] {
        [CacheDirectory(url: home.appendingPathComponent(".cache/tuist"), title: "Общий кэш Tuist")]
    }

    public var archivesDirectory: URL { library("Developer/Xcode/Archives") }
    public var toolchainsDirectory: URL { library("Developer/Toolchains") }
    public var arcStoresDirectory: URL { home.appendingPathComponent(".arc/stores") }
    public var mainArcadiaMount: URL { home.appendingPathComponent("arcadia") }

    public var allClearable: [URL] {
        (xcodeCaches + previews + deviceSupport + simulatorCaches + globalProjectCaches).map(\.url)
    }

    /// The project caches inside one mount, each titled with the mount's own folder name followed
    /// by the path inside it: every mount contributes the same subpaths, only the mount tells them
    /// apart, and the same naming carries the discovered `.build` directories.
    public func projectCaches(inMount mount: URL, mountName: String) -> [CacheDirectory] {
        projectCacheSubpaths.map { subpath in
            CacheDirectory(
                url: mount.appendingPathComponent(subpath),
                title: "\(mountName) · \(subpath)"
            )
        }
    }
}

public enum CacheItemBuilder {
    /// Builds the rows without measuring them: every item leaves with `sizeBytes` nil so the list
    /// can be shown at once. `Scanner.measureSizes(for:onSize:)` fills the numbers in afterwards.
    public static func items(
        kind: CleanupKind,
        directories: [CacheDirectory],
        fileManager: FileManager = .default
    ) -> [CleanupItem] {
        directories.compactMap { directory in
            let url = directory.url
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
            else {
                return nil
            }
            return CleanupItem(
                id: url.path,
                kind: kind,
                title: directory.title,
                subtitle: url.path,
                action: .clearContents(url),
                sizeBytes: nil,
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
