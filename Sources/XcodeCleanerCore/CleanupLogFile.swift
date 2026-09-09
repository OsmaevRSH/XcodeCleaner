import Foundation

public actor CleanupLogFile {
    public nonisolated let fileURL: URL
    private let handle: FileHandle

    public init(directory: URL, runID: String = CleanupLogFile.defaultRunID()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cleanup-\(runID).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
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

    public func append(_ line: String) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    deinit {
        try? handle.close()
    }
}
