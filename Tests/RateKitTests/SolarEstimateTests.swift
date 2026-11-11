import XCTest
@testable import RateKit

final class SolarEstimateTests: XCTestCase {
    let flat = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
    let tenCents = PlanTerms(energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)   // $100 a month at 1,000 kWh

    func testEachAreaUsesItsCitysOutput() {
        XCTAssertEqual(SolarEstimate.kWhPerKW(tdu: .centerPoint, zip: "77002").reduce(0, +), 1421, accuracy: 1)
        XCTAssertEqual(SolarEstimate.kWhPerKW(tdu: .oncor, zip: "75094").reduce(0, +), 1506, accuracy: 1)
        XCTAssertEqual(SolarEstimate.kWhPerKW(tdu: .oncor, zip: "79701").reduce(0, +), 1747, accuracy: 1)
        XCTAssertEqual(SolarEstimate.kWhPerKW(tdu: .aepNorth, zip: "79601").reduce(0, +), 1650, accuracy: 1)
        XCTAssertEqual(SolarEstimate.kWhPerKW(tdu: .aepCentral, zip: "78401").reduce(0, +), 1523, accuracy: 1)
        XCTAssertEqual(SolarEstimate.city(tdu: .lubbock, zip: "79401"), .midland)
        XCTAssertEqual(SolarEstimate.city(tdu: .tnmp, zip: "79772"), .midland)
        XCTAssertEqual(SolarEstimate.city(tdu: .tnmp, zip: "77590"), .houston)
        XCTAssertEqual(SolarEstimate.city(tdu: .oncorNTU, zip: "76201"), .dallas)
    }

    func testABillCreditLostToSolarCountsAgainstTheSaving() {
        // $100 off any month of 1,000 kWh or more: with panels covering part of each month, it's lost.
        var credit = tenCents
        credit.credits = [UsageCredit(amount: 100, minKWh: 1000)]
        let s = SolarEstimate(kW: 5, tdu: .oncor, zip: "75094", usage: flat, terms: credit, usedAsMade: 0.5, buybackCents: 0)
        XCTAssertEqual(s.yearWithout, 0, accuracy: 0.01)
        XCTAssertLessThan(s.yearlySaving, 0)
        XCTAssertNil(s.paybackYears)
    }

    func testPowerUsedAtHomeIsBoughtNoLongerAndExportsEarnTheBuyback() throws {
        // Dallas, 5 kW: 7,530 kWh a year. Half used as made, half sent out at 5¢.
        let s = SolarEstimate(kW: 5, tdu: .oncor, zip: "75094", usage: flat, terms: tenCents, usedAsMade: 0.5, buybackCents: 5)
        XCTAssertEqual(s.yearlyProduction, 7530, accuracy: 1)
        XCTAssertEqual(s.coverage, 7530.0 / 12000, accuracy: 0.001)
        XCTAssertEqual(s.yearWithout, 1200, accuracy: 0.01)
        // 3,765 kWh not bought at 10¢ ($376.50) and 3,765 kWh sold at 5¢ ($188.25).
        XCTAssertEqual(s.yearlySaving, 376.5 + 188.25, accuracy: 0.5)
        XCTAssertEqual(s.cost, 15_000...18_000)
        let payback = try XCTUnwrap(s.paybackYears)
        XCTAssertEqual(payback.lowerBound, 15_000 / s.yearlySaving, accuracy: 0.01)
    }

    func testUsedAtHomeNeverExceedsTheMonthsUsage() {
        let small = YearOfUsage(kWh: Array(repeating: 100, count: 12), estimated: Array(repeating: false, count: 12))
        let s = SolarEstimate(kW: 10, tdu: .centerPoint, zip: "77002", usage: small, terms: tenCents, usedAsMade: 1, buybackCents: 0)
        XCTAssertTrue(s.usedAtHome.allSatisfy { $0 <= 100 })
        XCTAssertEqual(s.yearWith, 0, accuracy: 0.01)
        // Without a buyback, the rest earns nothing.
        XCTAssertEqual(s.yearlySaving, 120, accuracy: 0.01)
    }
}
