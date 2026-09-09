import Foundation

public struct RunningAppsCheck: Sendable {
    public static let watchedProcesses = ["Xcode", "Simulator", "xcodebuild", "xctest"]

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// `pgrep` exits 0 when it matched, 1 when it did not, and 2 or 3 on usage/system errors.
    /// Treating anything but 0 as "not running" would let a broken `pgrep` green-light deleting
    /// caches out from under a live Xcode, so every other outcome is an error.
    public func blockingProcesses() async throws -> [String] {
        var running: [String] = []
        for name in Self.watchedProcesses {
            let result: CommandResult
            do {
                result = try await runner.run("pgrep", ["-x", name])
            } catch let error as CancellationError {
                throw error
            } catch let error as CommandError {
                throw error
            } catch {
                throw CommandError(executable: "pgrep", message: "\(error)")
            }
            if result.terminatedBySignal {
                throw CommandError(executable: "pgrep", message: "killed by signal \(result.exitCode)")
            }
            switch result.exitCode {
            case 0:
                running.append(name)
            case 1:
                continue
            default:
                let details = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
                throw CommandError(executable: "pgrep", message: "pgrep -x \(name): \(details)")
            }
        }
        return running
    }
}
