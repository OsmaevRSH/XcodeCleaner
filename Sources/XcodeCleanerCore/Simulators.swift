import Foundation

public struct SimulatorDevice: Sendable, Equatable, Decodable {
    public let udid: String
    public let name: String
    public let isAvailable: Bool
    public let state: String
    public let dataPathSize: Int64?
}

public struct SimulatorRuntime: Sendable, Equatable, Decodable {
    public let identifier: String
    public let runtimeIdentifier: String
    public let version: String
    public let platformIdentifier: String?
    private let rawSizeBytes: Int64?
    private let rawDeletable: Bool?

    public var sizeBytes: Int64 { rawSizeBytes ?? 0 }
    public var deletable: Bool { rawDeletable ?? false }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case runtimeIdentifier
        case version
        case platformIdentifier
        case rawSizeBytes = "sizeBytes"
        case rawDeletable = "deletable"
    }
}

public struct SimulatorInventory: Sendable, Equatable {
    public let devices: [SimulatorDevice]
    public let runtimes: [SimulatorRuntime]

    public init(devices: [SimulatorDevice], runtimes: [SimulatorRuntime]) {
        self.devices = devices
        self.runtimes = runtimes
    }

    public var availableDevices: [SimulatorDevice] { devices.filter(\.isAvailable) }
    public var unavailableDevices: [SimulatorDevice] { devices.filter { $0.isAvailable == false } }
    public var devicesDataSize: Int64 { devices.reduce(0) { $0 + ($1.dataPathSize ?? 0) } }
    public var runtimesSize: Int64 { runtimes.filter(\.deletable).reduce(0) { $0 + $1.sizeBytes } }

    public func estimatedFreedBytes(for mode: SimulatorMode) -> Int64 {
        switch mode {
        case .deleteUnavailable:
            unavailableDevices.reduce(0) { $0 + ($1.dataPathSize ?? 0) }
        case .eraseAll, .deleteAll:
            devicesDataSize
        case .deleteAllAndRuntimes:
            devicesDataSize + runtimesSize
        }
    }

    public func makeItem(mode: SimulatorMode) -> CleanupItem {
        CleanupItem(
            id: "simulators",
            kind: .simulators,
            title: mode.title,
            subtitle: "\(RussianPlural.devices(devices.count)), \(unavailableDevices.count) недоступно, \(runtimes.count) runtimes",
            action: .simulators(mode),
            sizeBytes: estimatedFreedBytes(for: mode),
            isDestructive: mode.isDestructive
        )
    }

    private struct DevicesPayload: Decodable {
        let devices: [String: [SimulatorDevice]]
    }

    public static func parse(devicesJSON: Data, runtimesJSON: Data) throws -> SimulatorInventory {
        let decoder = JSONDecoder()
        let devicesPayload = try decoder.decode(DevicesPayload.self, from: devicesJSON)
        let runtimesPayload = try decoder.decode([String: SimulatorRuntime].self, from: runtimesJSON)
        return SimulatorInventory(
            devices: devicesPayload.devices.values.flatMap { $0 }.sorted { $0.udid < $1.udid },
            runtimes: runtimesPayload.values.sorted { $0.identifier < $1.identifier }
        )
    }
}

public struct SimulatorScanner: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func inventory() async throws -> SimulatorInventory {
        let devices = try await runner.run("xcrun", ["simctl", "list", "devices", "-j"])
        let runtimes = try await runner.run("xcrun", ["simctl", "runtime", "list", "-j"])
        guard devices.succeeded, runtimes.succeeded else {
            throw CommandError(executable: "xcrun", message: devices.stderr + runtimes.stderr)
        }
        return try SimulatorInventory.parse(
            devicesJSON: Data(devices.stdout.utf8),
            runtimesJSON: Data(runtimes.stdout.utf8)
        )
    }
}
