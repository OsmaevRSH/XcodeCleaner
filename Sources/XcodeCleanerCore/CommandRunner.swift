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
        try await run(executable, arguments, currentDirectory: currentDirectory, onOutputLine: onOutputLine)
    }
}

public struct ExecutableLocator: Sendable {
    public let searchDirectories: [String]

    public init(searchDirectories: [String]) {
        self.searchDirectories = searchDirectories
    }

    public static var standard: ExecutableLocator {
        let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let wellKnown = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let merged = (wellKnown + fromEnvironment).filter { seen.insert($0).inserted }
        return ExecutableLocator(searchDirectories: merged)
    }

    public func resolve(_ name: String) -> String? {
        if name.hasPrefix("/") {
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

        do {
            try process.run()
        } catch {
            throw CommandError(executable: executable, message: error.localizedDescription)
        }

        async let stdoutText = Self.collect(stdoutPipe.fileHandleForReading, onOutputLine)
        async let stderrText = Self.collect(stderrPipe.fileHandleForReading, onOutputLine)
        let stdout = await stdoutText
        let stderr = await stderrText
        process.waitUntilExit()
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func collect(
        _ handle: FileHandle,
        _ onOutputLine: (@Sendable (String) -> Void)?
    ) async -> String {
        var lines: [String] = []
        do {
            for try await line in handle.bytes.lines {
                lines.append(line)
                onOutputLine?(line)
            }
        } catch {
            lines.append("[read error] \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
