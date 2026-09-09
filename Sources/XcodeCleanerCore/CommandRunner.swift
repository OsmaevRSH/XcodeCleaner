import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public struct CommandError: Error, Equatable, Sendable {
    public let executable: String
    public let message: String

    public init(executable: String, message: String) {
        self.executable = executable
        self.message = message
    }
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
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
                process: process,
                executable: executable,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                onOutputLine: onOutputLine
            )
        } onCancel: {
            processBox.process.terminate()
        }
    }

    /// Not Sendable itself, but only ever touched from the `onCancel` closure of
    /// `withTaskCancellationHandler`, which cannot run concurrently with the rest of `run`.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process

        init(process: Process) {
            self.process = process
        }
    }

    private static func runAndCollect(
        process: Process,
        executable: String,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
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
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: CommandError(executable: executable, message: error.localizedDescription))
            }
        }

        do {
            let stdout = try await stdoutText
            let stderr = try await stderrText
            return CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
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
