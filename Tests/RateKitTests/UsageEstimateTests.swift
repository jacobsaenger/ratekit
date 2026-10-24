import XCTest
@testable import RateKit

final class UsageEstimateTests: XCTestCase {
    func testSharesCoverTheYear() {
        XCTAssertEqual(UsageEstimate.texasMonthlyShare.count, 12)
        XCTAssertEqual(UsageEstimate.texasMonthlyShare.reduce(0, +), 1, accuracy: 0.00001)
        // August is the peak month, April the low.
        XCTAssertEqual(UsageEstimate.texasMonthlyShare.firstIndex(of: UsageEstimate.texasMonthlyShare.max()!), 7)
        XCTAssertEqual(UsageEstimate.texasMonthlyShare.firstIndex(of: UsageEstimate.texasMonthlyShare.min()!), 3)
    }

    func testFillKeepsKnownMonthsAndScalesTheRest() throws {
        // One known month: August 1,600 kWh → a year of 1,600 / 0.1224628 ≈ 13,065 kWh.
        let year = try XCTUnwrap(UsageEstimate.fill([7: 1600]))
        XCTAssertEqual(year.kWh[7], 1600)
        XCTAssertFalse(year.estimated[7])
        XCTAssertEqual(year.estimated.filter { $0 }.count, 11)
        XCTAssertEqual(year.kWh[3], (1600 / 0.1224628 * 0.0591686).rounded())
        XCTAssertEqual(year.total, 13065, accuracy: 6)
    }

    func testFillWithAFullYearChangesNothing() throws {
        let bills: [Double] = [1100, 950, 800, 780, 990, 1300, 1550, 1640, 1380, 1070, 820, 900]
        let year = try XCTUnwrap(UsageEstimate.fill(Dictionary(uniqueKeysWithValues: bills.enumerated().map { ($0, $1) })))
        XCTAssertEqual(year.kWh, bills)
        XCTAssertEqual(year.estimated, Array(repeating: false, count: 12))
    }

    func testFillNeedsAtLeastOneMonth() {
        XCTAssertNil(UsageEstimate.fill([:]))
        XCTAssertNil(UsageEstimate.fill([12: 900]))
    }

    func testEstimateFromHomeSize() {
        let year = UsageEstimate.estimate(for: .house1500to1999)
        XCTAssertEqual(year.total, 13761, accuracy: 6)
        XCTAssertTrue(year.estimated.allSatisfy { $0 })
        XCTAssertGreaterThan(year.kWh[7], year.kWh[3])
    }
}
