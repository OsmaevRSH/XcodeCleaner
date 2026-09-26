import Foundation

public extension CachePaths {
    /// Turns lines a person typed into search roots, and says why anything was thrown away.
    ///
    /// The rules are the ones the walk needs, not a general path grammar. A root is a path relative
    /// to a mount, so slashes around it are noise; `..` is the one component that would take a
    /// recursive walk out of the mount and into the rest of the disk, which is exactly what a
    /// cleanup tool must never do. The same rules answer for a list typed in the settings sheet and
    /// for one written straight into `UserDefaults`, so both go through here.
    ///
    /// A blank line is not a rejection: it is how a hand-typed list ends, and reporting it in red
    /// would make the ordinary case look broken. A line that holds something but names nothing —
    /// `/` — is a rejection, because the user meant to write a path there.
    ///
    /// Order is the user's, and a root repeated in it is kept once: two lines naming the same
    /// directory would walk it twice and offer every `.build` under it twice.
    static func normalizedSearchRoots(
        _ lines: [String]
    ) -> (roots: [String], rejected: [(line: String, reason: String)]) {
        var roots: [String] = []
        var rejected: [(line: String, reason: String)] = []
        var seen = Set<String>()
        for line in lines {
            guard line.trimmingCharacters(in: .whitespaces).isEmpty == false else { continue }
            let root = line.trimmingCharacters(in: searchRootPadding)
            guard root.isEmpty == false else {
                rejected.append((line, "пустая строка"))
                continue
            }
            guard root.components(separatedBy: "/").contains("..") == false else {
                rejected.append((line, "путь наружу из маунта"))
                continue
            }
            if seen.insert(root).inserted {
                roots.append(root)
            }
        }
        return (roots, rejected)
    }

    /// What surrounds a root without being part of it. Only the ends are trimmed: a directory name
    /// is allowed to contain spaces.
    private static let searchRootPadding = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/"))

    /// Turns folders picked in the settings sheet, or written into `UserDefaults` by hand, into the
    /// absolute folders the walk starts from, and says why anything was thrown away.
    ///
    /// Unlike a search root, a folder is not confined to a mount, so the rules are about the disk:
    /// the path has to be absolute (after `~` is expanded against `home`), and it may not be the
    /// whole disk or one of the system roots — walking those finds no projects, and a cleanup tool
    /// has no business listing them. The check runs on the standardized path, so `/usr/local/..`
    /// is `/usr`, and ignores case, as the filesystem does. Folders *inside* a system root stay
    /// allowed: a project may live in `/opt/src`.
    ///
    /// Whether the folder exists is deliberately not checked: a folder on a drive that is not
    /// plugged in right now is still the user's setting, and the scan reports it as skipped.
    ///
    /// Blank lines are skipped without a word, order is the user's, and a folder named twice — `~/x`
    /// and `/Users/<login>/x/` — is kept once.
    static func normalizedSearchFolders(
        _ lines: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (folders: [URL], rejected: [(line: String, reason: String)]) {
        var folders: [URL] = []
        var rejected: [(line: String, reason: String)] = []
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            let expanded = expandingTilde(trimmed, home: home)
            guard expanded.hasPrefix("/") else {
                rejected.append((line, "нужен полный путь"))
                continue
            }
            let folder = URL(fileURLWithPath: expanded).standardizedFileURL
            let path = folder.path
            guard path != "/" else {
                rejected.append((line, "это весь диск"))
                continue
            }
            guard systemRoots.contains(path.lowercased()) == false else {
                rejected.append((line, "системная папка"))
                continue
            }
            if seen.insert(path).inserted {
                folders.append(folder)
            }
        }
        return (folders, rejected)
    }

    /// Where the system lives. Walking any of these finds no projects — and a folder this broad is
    /// a misclick in the folder picker, not a choice.
    private static let systemRoots: Set<String> = [
        "/system", "/library", "/applications", "/usr", "/private", "/bin", "/sbin", "/opt",
    ]

    /// `~` and `~/…` only. `~someone/…` names another user's home, which is not where this user's
    /// projects are, so it stays unexpanded and is rejected as not absolute.
    private static func expandingTilde(_ path: String, home: URL) -> String {
        if path == "~" {
            return home.path
        }
        guard path.hasPrefix("~/") else { return path }
        return home.path + path.dropFirst(1)
    }
}
