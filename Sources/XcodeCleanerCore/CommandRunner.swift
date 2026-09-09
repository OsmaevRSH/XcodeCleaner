import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// When true, `exitCode` carries the number of the signal that killed the process rather than
    /// an exit status — `15` means `SIGTERM`, not "the command exited with 15".
    public let terminatedBySignal: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, terminatedBySignal: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.terminatedBySignal = terminatedBySignal
    }

    public var succeeded: Bool { exitCode == 0 }
}

public struct CommandError: Error, Equatable, Sendable, LocalizedError {
    public let executable: String
    public let message: String

    public init(executable: String, message: String) {
        self.executable = executable
        self.message = message
    }

    public var errorDescription: String? { "\(executable): \(message)" }
}

public protocol CommandRunning: Sendable {
    /// - Parameter onOutputLine: May be called concurrently from the stdout and stderr readers;
    ///   implementations must be thread-safe.
    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, currentDirectory: nil, onOutputLine: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(executable, arguments, currentDirectory: nil, onOutputLine: onOutputLine)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments,
            currentDirectory: Optional(currentDirectory),
            onOutputLine: Optional(onOutputLine)
        )
    }
}

public struct ExecutableLocator: Sendable {
    public let searchDirectories: [String]

    public init(searchDirectories: [String]) {
        self.searchDirectories = searchDirectories
    }

    public static let standard: ExecutableLocator = {
        let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let wellKnown = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let merged = (wellKnown + fromEnvironment).filter { seen.insert($0).inserted }
        return ExecutableLocator(searchDirectories: merged)
    }()

    public func resolve(_ name: String) -> String? {
        if name.contains("/") {
            return Self.isRunnableFile(atPath: name) ? name : nil
        }
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if Self.isRunnableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// `isExecutableFile(atPath:)` is true for directories too (the execute bit means "searchable"
    /// there), so a bare path like `/tmp` would otherwise be handed to `Process` and fail at spawn.
    private static func isRunnableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

public final class ProcessCommandRunner: CommandRunning {
    private let locator: ExecutableLocator

    public init(locator: ExecutableLocator = .standard) {
        self.locator = locator
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        guard let path = locator.resolve(executable) else {
            throw CommandError(executable: executable, message: "Executable not found in search directories")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = locator.searchDirectories.joined(separator: ":")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = ProcessBox(process: process)

        return try await withTaskCancellationHandler {
            try await Self.runAndCollect(
                box: processBox,
                executable: executable,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                onOutputLine: onOutputLine
            )
        } onCancel: {
            processBox.terminate()
        }
    }

    /// `onCancel` of `withTaskCancellationHandler` runs synchronously on whichever thread calls
    /// `cancel()`, and it runs immediately (before the body) when the task is already cancelled —
    /// so it *can* race the launch. `Process.terminate()` raises an uncatchable
    /// `NSInvalidArgumentException` when the task was never launched, so launch and terminate are
    /// serialised here and cancellation that wins the race prevents the launch altogether.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var launched = false
        private var cancelled = false

        init(process: Process) {
            self.process = process
        }

        func launch() throws {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
                launched = true
            }
        }

        func terminate() {
            lock.withLock {
                cancelled = true
                if launched, process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private static func runAndCollect(
        box: ProcessBox,
        executable: String,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        let process = box.process
        // Draining must start before we await process termination: pipes have a 64KB buffer,
        // and a process that fills it while nobody is reading will block forever, which would
        // in turn block termination and deadlock this function.
        async let stdoutText = collect(stdoutPipe.fileHandleForReading, onOutputLine)
        async let stderrText = collect(stderrPipe.fileHandleForReading, onOutputLine)

        let exitCode = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
            do {
                try box.launch()
            } catch {
                // Nothing was spawned, so this process still holds the only copies of the pipes'
                // write ends. Unless they are closed the readers above never see EOF, and the
                // implicit await that unwinds the `async let` bindings would hang forever.
                process.terminationHandler = nil
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                if error is CancellationError {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        throwing: CommandError(executable: executable, message: error.localizedDescription)
                    )
                }
            }
        }
        process.terminationHandler = nil
        try Task.checkCancellation()

        do {
            let stdout = try await stdoutText
            let stderr = try await stderrText
            return CommandResult(
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr,
                terminatedBySignal: process.terminationReason == .uncaughtSignal
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CommandError(executable: executable, message: "\(error)")
        }
    }

    // `FileHandle.bytes.lines` deadlocks when two instances are iterated concurrently (as two
    // sibling tasks/`async let` bindings draining stdout and stderr at once) — verified this hangs
    // indefinitely even on trivial output. Read with the throwing, non-async `read(upToCount:)`
    // API on a dedicated background queue instead, bridged to async via a checked continuation.
    private static func collect(
        _ handle: FileHandle,
        _ onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var lines: [String] = []
                    var pending = Data()
                    while let chunk = try handle.read(upToCount: 65536), chunk.isEmpty == false {
                        pending.append(chunk)
                        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = pending[pending.startIndex..<newlineIndex]
                            let line = String(decoding: lineData, as: UTF8.self)
                            lines.append(line)
                            onOutputLine?(line)
                            pending.removeSubrange(pending.startIndex...newlineIndex)
                        }
                    }
                    if pending.isEmpty == false {
                        let line = String(decoding: pending, as: UTF8.self)
                        lines.append(line)
                        onOutputLine?(line)
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
