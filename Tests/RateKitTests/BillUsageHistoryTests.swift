import XCTest
@testable import RateKit

/// Layouts from providers' published sample bills (research notes, 2026-10-23), as the
/// scanner joins each printed row into one line. Not yet checked against real bills.
final class BillUsageHistoryTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))! }

    func read(_ text: String) -> [MonthlyUsage] { BillUsageHistory.read(text, now: now, calendar: calendar) }

    /// Reliant: three months over their usage, oldest first.
    func testMonthColumnsOverAUsageRow() {
        let text = """
        Electricity Usage Summary
        Billing Period  JUL  AUG  SEP
        Billing Days  31  31  30
        Electricity Used (kWh)  1,132  1,465  1,000
        Average High Temp  99º  97º  95º
        Service Period 08/22/2026 - 09/21/2026
        """
        XCTAssertEqual(read(text), [
            MonthlyUsage(year: 2026, month: 7, kWh: 1132),
            MonthlyUsage(year: 2026, month: 8, kWh: 1465),
            MonthlyUsage(year: 2026, month: 9, kWh: 1000),
        ])
    }

    /// Columns named by the month the meter was read: the newest is this bill's period
    /// (mostly September), not October, and every column moves back one.
    func testColumnsNamedByReadMonth() {
        let text = """
        Billing Period  AUG  SEP  OCT
        Electricity Used (kWh)  1,132  1,465  1,000
        Service Period 09/05/2026 - 10/04/2026
        """
        XCTAssertEqual(read(text), [
            MonthlyUsage(year: 2026, month: 7, kWh: 1132),
            MonthlyUsage(year: 2026, month: 8, kWh: 1465),
            MonthlyUsage(year: 2026, month: 9, kWh: 1000),
        ])
    }

    /// Columns newest first, across a new year, dated from today when there's no period line.
    func testNewestFirstAcrossTheYear() {
        let text = """
        FEB  JAN  DEC
        Electricity Used (kWh)  1984  2081  2025
        """
        let later = calendar.date(from: DateComponents(year: 2027, month: 3, day: 5))!
        XCTAssertEqual(BillUsageHistory.read(text, now: later, calendar: calendar), [
            MonthlyUsage(year: 2026, month: 12, kWh: 2025),
            MonthlyUsage(year: 2027, month: 1, kWh: 2081),
            MonthlyUsage(year: 2027, month: 2, kWh: 1984),
        ])
    }

    /// TXU: 13 months as a chart. Its only numbers are axis ticks, which aren't usage.
    func testChartAxisIsNotUsage() {
        let text = """
        Your Electricity Usage
        AUG  SEP  OCT  NOV  DEC  JAN  FEB  MAR  APR  MAY  JUN  JUL  AUG
        kWh Used  987  846  705  564  423  282  141  0
        """
        XCTAssertEqual(read(text), [])
        XCTAssertTrue(BillUsageHistory.isAxis([987, 846, 705, 564, 423, 282, 141, 0]))
    }

    /// Constellation: labelled months, dated by the billing period. "Last Year 0 kWh" means
    /// no data, not zero use.
    func testCurrentLastMonthAndLastYear() {
        let text = """
        Billing Period: 09/10/2026 - 10/09/2026
        MONTHLY USAGE
        Current Month  1,767 kWh
        Last Month  2,654 kWh
        Last Year  0 kWh
        """
        XCTAssertEqual(read(text), [
            MonthlyUsage(year: 2026, month: 8, kWh: 2654),
            MonthlyUsage(year: 2026, month: 9, kWh: 1767),
        ])
    }

    /// A bill with only its own period: one month, the one most of the period falls in.
    func testSinglePeriod() {
        let text = """
        Service from 08/29/2026 to 09/27/2026
        Electricity used (kWh)  1,203
        """
        XCTAssertEqual(read(text), [MonthlyUsage(year: 2026, month: 9, kWh: 1203)])
    }

    /// Without a period line, a lone usage figure can't be placed in a month.
    func testUsageWithoutDatesIsNotPlaced() {
        XCTAssertEqual(read("kWh Usage  303"), [])
    }

    /// Daily averages and temperatures share the table but aren't monthly usage, and a
    /// sentence that happens to name months isn't a heading row.
    func testOtherRowsAndSentencesAreIgnored() {
        let text = """
        JUL  AUG  SEP
        Avg. Daily Usage (kWh)  36  47  33
        Your rate for Jul and Aug was lower.
        """
        XCTAssertEqual(read(text), [])
        XCTAssertEqual(BillUsageHistory.monthTokens("Your rate for Jul and Aug was lower."), [7])
    }
}
