import Foundation

public struct ItemResult: Sendable, Equatable, Identifiable {
    public let itemID: String
    public let succeeded: Bool
    public let message: String?

    public var id: String { itemID }

    public init(itemID: String, succeeded: Bool, message: String?) {
        self.itemID = itemID
        self.succeeded = succeeded
        self.message = message
    }
}

public struct CleanupReport: Sendable, Equatable {
    public let diskBefore: DiskSpace?
    public let diskAfter: DiskSpace?
    public let results: [ItemResult]

    public init(diskBefore: DiskSpace?, diskAfter: DiskSpace?, results: [ItemResult]) {
        self.diskBefore = diskBefore
        self.diskAfter = diskAfter
        self.results = results
    }

    public var failureCount: Int { results.filter { $0.succeeded == false }.count }

    public var freedBytes: Int64? {
        guard let diskBefore, let diskAfter else { return nil }
        return diskAfter.available - diskBefore.available
    }
}

public enum CleanerError: Error, Equatable, Sendable, LocalizedError {
    case blockingProcesses([String])

    public var errorDescription: String? {
        switch self {
        case .blockingProcesses(let names):
            "Закройте перед очисткой: \(names.joined(separator: ", "))"
        }
    }
}

public struct Cleaner: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let runner: any CommandRunning
    private let deleter: SafeDeleter
    // Any injected `FileManager` must be thread-safe (the shared default instance is); it is only
    // read.
    private nonisolated(unsafe) let fileManager: FileManager
    private let home: URL

    public init(runner: any CommandRunning, deleter: SafeDeleter, fileManager: FileManager = .default, home: URL) {
        self.runner = runner
        self.deleter = deleter
        self.fileManager = fileManager
        self.home = home
    }

    public static func ordered(_ items: [CleanupItem]) -> [CleanupItem] {
        let rank = Dictionary(uniqueKeysWithValues: CleanupKind.executionOrder.enumerated().map { ($1, $0) })
        return items.sorted { (rank[$0.kind] ?? .max, $0.id) < (rank[$1.kind] ?? .max, $1.id) }
    }

    public func run(_ items: [CleanupItem], log: @escaping Log) async throws -> CleanupReport {
        // A run cancelled before it starts must not spawn `pgrep`, shut simulators down or delete
        // anything; it still reports so the caller sees the (empty) outcome and the disk figures.
        if Task.isCancelled == false {
            let blocking = try await RunningAppsCheck(runner: runner).blockingProcesses()
            guard blocking.isEmpty else {
                throw CleanerError.blockingProcesses(blocking)
            }
        }

        let ordered = Self.ordered(items)
        let diskBefore = try? DiskSpace.current(for: home)
        log("Начало: \(Date().formatted(date: .numeric, time: .standard))")
        if let diskBefore {
            log("Свободно до: \(ByteFormatting.string(diskBefore.available))")
        }

        // Booted simulators keep their data directories busy, so every simulator-touching run
        // shuts them down once up front rather than per item.
        let touchesSimulators = ordered.contains { $0.kind == .simulators || $0.kind == .simulatorCaches }
        if touchesSimulators, Task.isCancelled == false {
            _ = await simctl(["shutdown", "all"], log: log)
        }

        var results: [ItemResult] = []
        for item in ordered {
            if Task.isCancelled {
                break
            }
            log("→ \(item.kind.title): \(item.title)")
            let result = await perform(item, log: log)
            if let message = result.message {
                log(result.succeeded ? "  \(message)" : "  ✗ \(message)")
            }
            results.append(result)
        }

        if Task.isCancelled {
            log("Прервано пользователем")
        }
        _ = try? await runner.run("sync", [])
        let diskAfter = try? DiskSpace.current(for: home)
        let report = CleanupReport(diskBefore: diskBefore, diskAfter: diskAfter, results: results)
        if let diskAfter {
            log("Свободно после: \(ByteFormatting.string(diskAfter.available))")
        }
        if let freed = report.freedBytes {
            log("Освободилось по факту: \(ByteFormatting.string(freed))")
        }
        log("Ошибок: \(report.failureCount)")
        return report
    }

    private func perform(_ item: CleanupItem, log: @escaping Log) async -> ItemResult {
        switch item.action {
        case let .clearContents(directory):
            do {
                let failures = try deleter.clearContents(of: directory, fileManager: fileManager)
                for failure in failures {
                    log("  ✗ \(failure.path): \(failure.reason)")
                }
                return ItemResult(
                    itemID: item.id,
                    succeeded: failures.isEmpty,
                    message: failures.isEmpty ? nil : "\(failures.count) объектов не удалено"
                )
            } catch {
                return ItemResult(itemID: item.id, succeeded: false, message: error.localizedDescription)
            }
        case let .trash(url):
            do {
                try deleter.trash(url, fileManager: fileManager)
                return ItemResult(itemID: item.id, succeeded: true, message: "в Корзину")
            } catch {
                return ItemResult(itemID: item.id, succeeded: false, message: error.localizedDescription)
            }
        case let .simulators(mode):
            return await performSimulators(mode, itemID: item.id, log: log)
        }
    }

    private func performSimulators(_ mode: SimulatorMode, itemID: String, log: @escaping Log) async -> ItemResult {
        var commands: [[String]] = [
            ["delete", "unavailable"],
            ["runtime", "dyld_shared_cache", "remove", "--all"],
        ]
        switch mode {
        case .deleteUnavailable:
            break
        case .eraseAll:
            commands.append(["erase", "all"])
        case .deleteAll:
            commands.append(["delete", "all"])
        case .deleteAllAndRuntimes:
            commands.append(["delete", "all"])
            commands.append(["runtime", "delete", "all"])
        }
        // A failing `simctl` step never aborts the rest: the later commands clean up different
        // storage and are worth attempting even when an earlier one refused.
        var failures: [String] = []
        for command in commands {
            if let failure = await simctl(command, log: log) {
                failures.append(failure)
            }
        }
        return ItemResult(
            itemID: itemID,
            succeeded: failures.isEmpty,
            message: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
    }

    private func simctl(_ arguments: [String], log: @escaping Log) async -> String? {
        let label = "simctl \(arguments.joined(separator: " "))"
        log("  \(label)")
        do {
            let result = try await runner.run("xcrun", ["simctl"] + arguments, onOutputLine: { log("    \($0)") })
            guard result.succeeded else {
                return "\(label): \(Self.failureDetails(result))"
            }
            return nil
        } catch {
            return "\(label): \(error.localizedDescription)"
        }
    }

    /// `simctl` reports some refusals with an exit code and nothing on stderr, which would leave
    /// the user with a bare "simctl delete unavailable:" and no way to tell what went wrong.
    private static func failureDetails(_ result: CommandResult) -> String {
        if result.terminatedBySignal {
            return "killed by signal \(result.exitCode)"
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "exit \(result.exitCode)" : stderr
    }
}
