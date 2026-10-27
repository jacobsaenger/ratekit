import XCTest
@testable import RateKit

final class BillOutlookTests: XCTestCase {
    let usage = YearOfUsage(kWh: [800, 700, 800, 900, 1200, 1600, 1900, 2000, 1500, 1000, 800, 900],
                            estimated: Array(repeating: false, count: 12))

    /// CenterPoint's step from 6.413¢ to 6.5333¢ (same $4.90 a month): 0.1203¢ on every kWh.
    func testDeliveryChangeForTheYear() throws {
        let change = try XCTUnwrap(DeliveryChange(tdu: .centerPoint, old: TDUCharges(perKWh: 6.413, perMonth: 4.90),
                                                  new: TDUCharges(perKWh: 6.5333, perMonth: 4.90)))
        XCTAssertEqual(change.yearly(for: usage), 14_100 * 0.1203 / 100, accuracy: 0.0001)
        XCTAssertNil(DeliveryChange(tdu: .oncor, old: TDUCharges(perKWh: 6.8673, perMonth: 4.06),
                                    new: TDUCharges(perKWh: 6.8673, perMonth: 4.06)))
        let lower = try XCTUnwrap(DeliveryChange(tdu: .oncor, old: TDUCharges(perKWh: 7, perMonth: 4),
                                                 new: TDUCharges(perKWh: 7, perMonth: 3)))
        XCTAssertEqual(lower.yearly(for: usage), -12, accuracy: 1e-9)
    }

    /// From late November: November, December, then January of the next year.
    func testForecastRunsAcrossTheYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let terms = PlanTerms(baseCharge: 5, energyRate: 10, deliveryPerKWh: 6, deliveryPerMonth: 4)
        let months = BillForecast.months(3, terms: terms, usage: usage,
                                         from: calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!, calendar: calendar)
        XCTAssertEqual(months.map(\.month), [11, 12, 1])
        XCTAssertEqual(months.map(\.year), [2026, 2026, 2027])
        XCTAssertEqual(months[0].total, 800 * 16 / 100 + 9, accuracy: 1e-9)
        XCTAssertEqual(months[0].delivery, 800 * 6 / 100 + 4, accuracy: 1e-9)
        XCTAssertEqual(months[2].total, 800 * 16 / 100 + 9, accuracy: 1e-9)
    }
}
