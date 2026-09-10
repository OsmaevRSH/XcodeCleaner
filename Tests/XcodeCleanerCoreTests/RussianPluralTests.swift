import XCTest
@testable import XcodeCleanerCore

final class RussianPluralTests: XCTestCase {
    func test_oneTakesSingular() {
        XCTAssertEqual(RussianPlural.devices(1), "1 устройство")
        XCTAssertEqual(RussianPlural.mounts(1), "1 маунт")
    }

    func test_twoToFourTakeFewForm() {
        XCTAssertEqual(RussianPlural.devices(2), "2 устройства")
        XCTAssertEqual(RussianPlural.devices(4), "4 устройства")
        XCTAssertEqual(RussianPlural.mounts(3), "3 маунта")
    }

    func test_fiveAndUpTakeManyForm() {
        XCTAssertEqual(RussianPlural.devices(5), "5 устройств")
        XCTAssertEqual(RussianPlural.devices(0), "0 устройств")
        XCTAssertEqual(RussianPlural.mounts(11), "11 маунтов")
    }

    func test_teensTakeManyFormDespiteLastDigit() {
        XCTAssertEqual(RussianPlural.devices(11), "11 устройств")
        XCTAssertEqual(RussianPlural.devices(12), "12 устройств")
        XCTAssertEqual(RussianPlural.devices(14), "14 устройств")
        XCTAssertEqual(RussianPlural.devices(21), "21 устройство")
        XCTAssertEqual(RussianPlural.devices(22), "22 устройства")
    }

    func test_daysUseGenitiveAfterOlderThan() {
        XCTAssertEqual(RussianPlural.daysAfterOlderThan(1), "1 дня")
        XCTAssertEqual(RussianPlural.daysAfterOlderThan(30), "30 дней")
    }

    func test_simulatorSubtitleUsesTheRightForm() {
        let inventory = SimulatorInventory(devices: [], runtimes: [])
        XCTAssertEqual(inventory.makeItem(mode: .deleteAll).subtitle, "0 устройств, 0 недоступно, 0 runtimes")
    }
}
