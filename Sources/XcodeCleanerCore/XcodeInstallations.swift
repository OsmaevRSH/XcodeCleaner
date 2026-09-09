import Foundation

public struct XcodeInstallation: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isActive: Bool
    public let sizeBytes: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public func makeItem() -> CleanupItem {
        CleanupItem(
            id: url.path,
            kind: .xcodeApps,
            title: name,
            subtitle: url.path,
            action: .trash(url),
            sizeBytes: sizeBytes,
            isDestructive: true
        )
    }
}

public struct ToolchainEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isProtected: Bool
    public let sizeBytes: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public func makeItem() -> CleanupItem {
        CleanupItem(
            id: url.path,
            kind: .toolchains,
            title: name,
            subtitle: url.path,
            action: .trash(url),
            sizeBytes: sizeBytes,
            isDestructive: true
        )
    }
}

public enum XcodeInstallationScanner {
    public static func activeDeveloperDir(runner: any CommandRunning) async throws -> String {
        let result = try await runner.run("xcode-select", ["-p"])
        guard result.succeeded else {
            throw CommandError(executable: "xcode-select", message: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enumerator URLs can differ from caller-built URLs by trailing slash and, for `/var`-rooted
    /// temp dirs, by a `/private` prefix; entries are anchored to the caller's base so allowlist
    /// path comparison in `SafeDeleter` stays consistent.
    static func entryURL(base: URL, components: [String]) -> URL {
        let path = components.reduce(base) { $0.appendingPathComponent($1) }.path
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static func isXcodeAppName(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "Xcode" || stem.hasPrefix("Xcode-") || stem.hasPrefix("Xcode ")
    }

    public static func installations(
        in applications: URL,
        activeDeveloperDir: String,
        fileManager: FileManager = .default
    ) -> [XcodeInstallation] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let activePath = URL(fileURLWithPath: activeDeveloperDir).resolvingSymlinksInPath().path
        return children
            .filter(isXcodeAppName)
            .map { child in
                let url = Self.entryURL(base: applications, components: [child.lastPathComponent])
                let developerPath = url.appendingPathComponent("Contents/Developer").resolvingSymlinksInPath().path
                return XcodeInstallation(
                    url: url,
                    isActive: developerPath == activePath,
                    sizeBytes: DirectorySizer.size(of: child, fileManager: fileManager)
                )
            }
            .sorted { $0.name < $1.name }
    }

    public static func toolchains(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [ToolchainEntry] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let toolchainURLs = children.filter { $0.pathExtension == "xctoolchain" }
        let latestLink = toolchainURLs.first { $0.lastPathComponent == "swift-latest.xctoolchain" }
        let latestTarget = latestLink.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return toolchainURLs.map { child in
            let resolved = child.resolvingSymlinksInPath().standardizedFileURL.path
            let isLatestLink = child.lastPathComponent == "swift-latest.xctoolchain"
            let isLatestTarget = latestTarget == resolved
            let isSymlink = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let url = Self.entryURL(base: directory, components: [child.lastPathComponent])
            return ToolchainEntry(
                url: url,
                isProtected: isLatestLink || isLatestTarget,
                sizeBytes: isSymlink ? 0 : DirectorySizer.size(of: child, fileManager: fileManager)
            )
        }
        .sorted { $0.name < $1.name }
    }
}
