import Foundation

public actor CleanupLogFile {
    public nonisolated let fileURL: URL
    private let handle: FileHandle
    private nonisolated let continuation: AsyncStream<String>.Continuation
    private nonisolated(unsafe) var drainTask: Task<Void, Never>?

    public init(directory: URL, runID: String = CleanupLogFile.defaultRunID()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cleanup-\(runID).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        // The file is only ever appended to by this instance, so the offset is placed once here
        // instead of on every line.
        _ = try? handle.seekToEnd()
        self.handle = handle
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self)
        self.continuation = continuation
        drainTask = Task { [weak self] in
            for await line in stream {
                await self?.append(line)
            }
        }
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
    public func append(_ line: String) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Entry point for synchronous loggers: buffering through the stream keeps the lines in call
    /// order, which independently spawned `Task`s would not.
    public nonisolated func appendLine(_ line: String) {
        continuation.yield(line)
    }

    public func close() async {
        continuation.finish()
        await drainTask?.value
        drainTask = nil
        try? handle.close()
    }

    deinit {
        continuation.finish()
        try? handle.close()
    }
}
