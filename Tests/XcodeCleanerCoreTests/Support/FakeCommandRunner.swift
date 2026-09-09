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
    var responses: [String: CommandResult] = [:]
    var defaultResult = CommandResult(exitCode: 0, stdout: "", stderr: "")

    var calls: [Call] { lock.withLock { recorded } }
    var callLines: [String] { calls.map(\.line) }

    func respond(to line: String, stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        responses[line] = CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, currentDirectory: currentDirectory?.path)
        lock.withLock { recorded.append(call) }
        let result = responses[call.line] ?? defaultResult
        if let onOutputLine {
            for line in result.stdout.split(separator: "\n") {
                onOutputLine(String(line))
            }
        }
        return result
    }
}
