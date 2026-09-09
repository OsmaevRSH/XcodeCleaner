import Foundation

public struct RunningAppsCheck: Sendable {
    public static let watchedProcesses = ["Xcode", "Simulator", "xcodebuild", "xctest"]

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func blockingProcesses() async -> [String] {
        var running: [String] = []
        for name in Self.watchedProcesses {
            if let result = try? await runner.run("pgrep", ["-x", name]), result.succeeded {
                running.append(name)
            }
        }
        return running
    }
}
