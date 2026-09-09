import Foundation

/// Writes the cleanup log straight to disk under a lock: the callers are synchronous `Sendable`
/// closures invoked from background threads, and buffering their lines through an actor or a
/// stream would either reorder them or lose the tail when the app exits mid-run.
///
/// `@unchecked Sendable` because `FileHandle` is not `Sendable` and `isClosed` is mutable; both are
/// only ever touched inside `lock`.
public final class CleanupLogFile: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private let handle: FileHandle
    private var isClosed = false

    public init(directory: URL, runID: String = CleanupLogFile.defaultRunID()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cleanup-\(runID).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        // The file is only ever appended to by this instance, so the offset is placed once here
        // instead of on every line.
        _ = try? handle.seekToEnd()
    }

    public static func defaultRunID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: now)
    }

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Desktop/Xcode Cleanup Logs")
    }

    /// The non-throwing `FileHandle` writing API raises an Objective-C exception that no Swift
    /// `catch` can intercept, so a full disk would take the whole app down mid-cleanup.
    public func appendLine(_ line: String) {
        lock.withLock {
            guard isClosed == false else { return }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    public func append(_ line: String) {
        appendLine(line)
    }

    public func close() {
        lock.withLock {
            guard isClosed == false else { return }
            isClosed = true
            try? handle.close()
        }
    }

    deinit {
        close()
    }
}
