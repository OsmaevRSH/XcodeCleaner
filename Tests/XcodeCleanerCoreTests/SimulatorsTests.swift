import XCTest
@testable import XcodeCleanerCore

final class SimulatorsTests: XCTestCase {
    private let devicesJSON = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          {
            "udid" : "AAAA",
            "name" : "iPhone 17 Pro",
            "isAvailable" : true,
            "state" : "Booted",
            "dataPathSize" : 4000
          },
          {
            "udid" : "BBBB",
            "name" : "iPhone 15",
            "isAvailable" : false,
            "state" : "Shutdown",
            "dataPathSize" : 500
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-26-2" : [ ]
      }
    }
    """.data(using: .utf8)!

    private let runtimesJSON = """
    {
      "R1" : {
        "identifier" : "R1",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        "version" : "26.2",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "sizeBytes" : 8000,
        "deletable" : true
      },
      "R2" : {
        "identifier" : "R2",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
        "version" : "17.5",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "sizeBytes" : 7000,
        "deletable" : true
      }
    }
    """.data(using: .utf8)!

    func test_parsesDevicesAndRuntimes() throws {
        let inventory = try SimulatorInventory.parse(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON)

        XCTAssertEqual(inventory.devices.map(\.udid).sorted(), ["AAAA", "BBBB"])
        XCTAssertEqual(inventory.unavailableDevices.map(\.udid), ["BBBB"])
        XCTAssertEqual(inventory.runtimes.map(\.version).sorted(), ["17.5", "26.2"])
        XCTAssertEqual(inventory.devicesDataSize, 4500)
        XCTAssertEqual(inventory.runtimesSize, 15000)
    }

    func test_estimatedFreedBytesPerMode() throws {
        let inventory = try SimulatorInventory.parse(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON)

        XCTAssertEqual(inventory.estimatedFreedBytes(for: .deleteUnavailable), 500)
        XCTAssertEqual(inventory.estimatedFreedBytes(for: .eraseAll), 4500)
        XCTAssertEqual(inventory.estimatedFreedBytes(for: .deleteAll), 4500)
        XCTAssertEqual(inventory.estimatedFreedBytes(for: .deleteAllAndRuntimes), 19500)
    }

    func test_scannerCallsSimctl() async throws {
        let runner = FakeCommandRunner()
        runner.respond(to: "xcrun simctl list devices -j", stdout: String(data: devicesJSON, encoding: .utf8)!)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: String(data: runtimesJSON, encoding: .utf8)!)
        let scanner = SimulatorScanner(runner: runner)

        let inventory = try await scanner.inventory()

        XCTAssertEqual(inventory.devices.count, 2)
        XCTAssertEqual(runner.callLines, ["xcrun simctl list devices -j", "xcrun simctl runtime list -j"])
    }

    func test_makeItemUsesModeTitleAndEstimate() throws {
        let inventory = try SimulatorInventory.parse(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON)

        let item = inventory.makeItem(mode: .deleteAll)

        XCTAssertEqual(item.id, "simulators")
        XCTAssertEqual(item.kind, .simulators)
        XCTAssertEqual(item.action, .simulators(.deleteAll))
        XCTAssertEqual(item.sizeBytes, 4500)
        XCTAssertTrue(item.isDestructive)
        XCTAssertEqual(item.subtitle, "2 устройств, 1 недоступно, 2 runtimes")
    }
}
