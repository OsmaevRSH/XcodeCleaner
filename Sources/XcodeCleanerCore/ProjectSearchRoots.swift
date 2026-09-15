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
}
