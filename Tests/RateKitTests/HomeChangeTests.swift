import XCTest
@testable import RateKit

final class HomeChangeTests: XCTestCase {
    func total(_ change: HomeChange) -> Double { change.monthlyKWh.reduce(0, +) }

    func testAnElectricCarAddsItsMilesSpreadByDays() {
        // 11,026 miles at 0.30 kWh a mile.
        XCTAssertEqual(total(.electricCar), 3_307.8, accuracy: 0.1)
        XCTAssertEqual(HomeChange.electricCar.monthlyKWh[0], 3_307.8 * 31 / 365, accuracy: 0.01)
        XCTAssertEqual(HomeChange.electricCar.monthlyKWh[1], 3_307.8 * 28 / 365, accuracy: 0.01)
    }

    func testAPoolPumpRunsEveryDay() {
        XCTAssertEqual(total(.poolVariableSpeed), 2.2 * 365, accuracy: 0.01)
        XCTAssertEqual(total(.poolSingleSpeed), 12.6 * 365, accuracy: 0.01)
        // The DOE guide's own saving between the two: about 3,796 kWh a year.
        XCTAssertEqual(total(.poolSingleSpeed) - total(.poolVariableSpeed), 3_796, accuracy: 1)
    }

    func testANewAirConditionerSavesAThirdOfTexasCoolingInTheCoolingMonths() {
        // SEER 10 to 15 cuts cooling by a third: 13.6 million Btu a year in Texas.
        XCTAssertEqual(total(.newAirConditioner), -13.6 * 293.07 / 3, accuracy: 0.1)
        XCTAssertEqual(HomeChange.newAirConditioner.monthlyKWh[6], -2.9 * 293.07 / 3, accuracy: 0.01)
        XCTAssertTrue(HomeChange.newAirConditioner.monthlyKWh.allSatisfy { $0 < 0 })
    }

    func testAHeatPumpSavesOnWinterHeatOnly() {
        let months = HomeChange.heatPump.monthlyKWh
        XCTAssertEqual(months[11], -2.1 * 293.07 * (1 - 3.412 / 7.5), accuracy: 0.01)
        XCTAssertEqual(months[4...7].reduce(0, +), 0)
    }

    func testApplyingAChangeNeverGoesBelowZeroAndKeepsWhichMonthsAreEstimated() {
        let usage = YearOfUsage(kWh: Array(repeating: 100, count: 12), estimated: [true] + Array(repeating: false, count: 11))
        let cooler = HomeChange.newAirConditioner.applied(to: usage)
        XCTAssertEqual(cooler.kWh[6], 0)
        XCTAssertEqual(cooler.kWh[0], 100 - 0.1 * 293.07 / 3, accuracy: 0.01)
        XCTAssertEqual(cooler.estimated, usage.estimated)
        XCTAssertEqual(HomeChange.electricCar.applied(to: usage).kWh[0], 100 + 3_307.8 * 31 / 365, accuracy: 0.01)
    }
}
