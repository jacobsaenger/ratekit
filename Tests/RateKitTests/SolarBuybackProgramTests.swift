import XCTest
@testable import RateKit

final class SolarBuybackProgramTests: XCTestCase {
    func testTheBundledListLoadsWithFixedRatesFirst() throws {
        let list = SolarBuyback.list
        XCTAssertEqual(list.checked, "2026-11-11")
        XCTAssertGreaterThanOrEqual(list.programs.count, 10)
        XCTAssertEqual(list.programs.first?.id, "chariot-greenvolt")
        XCTAssertTrue(list.programs.allSatisfy { $0.source.hasPrefix("https://") })
        // Every fixed program has its rate, every time-of-day one its periods.
        XCTAssertTrue(list.programs.filter { $0.credit == .fixed }.allSatisfy { $0.cents != nil })
        XCTAssertTrue(list.programs.filter { $0.credit == .timeOfDay }.allSatisfy { !($0.periods ?? []).isEmpty })
    }

    func testOnlyAFixedRateGivesAYearlyCredit() throws {
        let fixed = try XCTUnwrap(SolarBuyback.list.programs.first { $0.id == "chariot-greenvolt" })
        XCTAssertEqual(try XCTUnwrap(fixed.yearlyCredit(exportKWh: 5000)), 350, accuracy: 0.001)
        let wholesale = try XCTUnwrap(SolarBuyback.list.programs.first { $0.id == "chariot-shine" })
        XCTAssertNil(wholesale.yearlyCredit(exportKWh: 5000))
    }
}
