import Foundation
@testable import XcodeCleanerCore

final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let currentDirectory: String?

        var line: String { ([executable] + arguments).joined(separator: " ") }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var storedResponses: [String: CommandResult] = [:]
    private var storedDefaultResult = CommandResult(exitCode: 0, stdout: "", stderr: "")
    private var storedErrorToThrow: CommandError?

    var calls: [Call] { lock.withLock { recorded } }
    var callLines: [String] { calls.map(\.line) }

    var defaultResult: CommandResult {
        get { lock.withLock { storedDefaultResult } }
        set { lock.withLock { storedDefaultResult = newValue } }
    }

    var errorToThrow: CommandError? {
        get { lock.withLock { storedErrorToThrow } }
        set { lock.withLock { storedErrorToThrow = newValue } }
    }

    func respond(to line: String, stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        lock.withLock {
            storedResponses[line] = CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
        }
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, currentDirectory: currentDirectory?.path)
        let (result, throwing): (CommandResult, CommandError?) = lock.withLock {
            recorded.append(call)
            let response = storedResponses[call.line] ?? storedDefaultResult
            return (response, storedErrorToThrow)
        }
        if let throwing {
            throw throwing
        }
        if let onOutputLine {
            Self.stream(result.stdout, to: onOutputLine)
            Self.stream(result.stderr, to: onOutputLine)
        }
        return result
    }

    /// Mirrors `ProcessCommandRunner`: both streams are reported, and empty output reports
    /// nothing at all rather than a single empty line.
    private static func stream(_ text: String, to onOutputLine: @Sendable (String) -> Void) {
        guard text.isEmpty == false else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            onOutputLine(String(line))
        }
    }
}
