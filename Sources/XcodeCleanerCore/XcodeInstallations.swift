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
        let activePath = URL(fileURLWithPath: activeDeveloperDir).standardizedFileURL.path
        return children
            .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
            .filter { $0.lastPathComponent != "Xcodes.app" }
            .map { child in
                // `contentsOfDirectory` resolves through `/private`; rebuild from the caller's own
                // `applications` base so the URL compares equal to ones built via
                // `appendingPathComponent` on that same (possibly non-`/private`) base.
                let url = applications.appendingPathComponent(child.lastPathComponent)
                let developer = url.appendingPathComponent("Contents/Developer").standardizedFileURL.path
                return XcodeInstallation(
                    url: url,
                    isActive: developer == activePath,
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
            // `contentsOfDirectory` resolves through `/private` and, because the entry already
            // exists on disk, `appendingPathComponent` also tags it with a directory-style
            // trailing slash; rebuild as a plain file URL so it compares equal to ones callers
            // build (before the directory exists) via `appendingPathComponent` on the same base.
            let url = URL(
                fileURLWithPath: directory.appendingPathComponent(child.lastPathComponent).path,
                isDirectory: false
            )
            return ToolchainEntry(
                url: url,
                isProtected: isLatestLink || isLatestTarget,
                sizeBytes: isLatestLink ? 0 : DirectorySizer.size(of: child, fileManager: fileManager)
            )
        }
        .sorted { $0.name < $1.name }
    }
}
