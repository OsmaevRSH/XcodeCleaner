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
            for line in result.stdout.split(separator: "\n") {
                onOutputLine(String(line))
            }
        }
        return result
    }
}
