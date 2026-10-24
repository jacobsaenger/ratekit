import XCTest
@testable import RateKit

final class SmartMeterImportTests: XCTestCase {
    let header = "ESIID,USAGE_DATE,REVISION_DATE,USAGE_START_TIME,USAGE_END_TIME,USAGE_KWH,ESTIMATED_ACTUAL,CONSUMPTION_SURPLUSGENERATION"

    /// 15-minute rows: `perInterval` kWh for every interval of every day in the range.
    func intervalFile(from start: (Int, Int), months: Int, perInterval: Double, solar: Bool = false) -> String {
        var lines = [header]
        var (year, month) = start
        let calendar = Calendar(identifier: .gregorian)
        for _ in 0..<months {
            let days = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month))!)!.count
            for day in 1...days {
                let date = String(format: "%02d/%02d/%04d", month, day, year)
                for q in 0..<96 {
                    let t = String(format: "%02d:%02d", q / 4, q % 4 * 15)
                    lines.append("'1008901000000000000001,\(date),\(date) 08:00:00,\(t),\(t),\(perInterval),A,Consumption")
                    if solar { lines.append("'1008901000000000000001,\(date),\(date) 08:00:00,\(t),\(t),0.5,A,Surplus Generation") }
                }
            }
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return lines.joined(separator: "\n")
    }

    func testIntervalFileSumsEachMonthAndLeavesOutSolarExport() throws {
        let result = try SmartMeterImport.read(intervalFile(from: (2026, 1), months: 2, perInterval: 0.25, solar: true))
        XCTAssertEqual(result.monthlyKWh[0], 31 * 96 * 0.25)   // January: 744 kWh
        XCTAssertEqual(result.monthlyKWh[1], 28 * 96 * 0.25)
        XCTAssertTrue(result.skippedSurplus)
    }

    func testKeepsTheLatestTwelveCompleteMonthsAndDropsAPartialOne() throws {
        var text = intervalFile(from: (2024, 11), months: 14, perInterval: 0.1)
        // One day of January 2026: a partial month, left out.
        text += "\n'1,01/01/2026,01/02/2026,00:00,00:15,5,A,Consumption"
        let result = try SmartMeterImport.read(text)
        XCTAssertEqual(result.months.count, 12)
        XCTAssertEqual(result.months.first, .init(year: 2025, month: 0))
        XCTAssertEqual(result.months.last, .init(year: 2025, month: 11))
    }

    func testRevisedIntervalsCountOnce() throws {
        var text = intervalFile(from: (2026, 3), months: 1, perInterval: 0.25)
        text += "\n'1,03/01/2026,03/05/2026 08:00:00,00:00,00:15,1.25,A,Consumption"
        let result = try SmartMeterImport.read(text)
        XCTAssertEqual(result.monthlyKWh[2], (31 * 96 * 0.25 + 1.0).rounded())
    }

    func testDailyReadsByMeterReading() throws {
        var lines = ["ESIID,READ_DATE,REVISION_DATE,START_READING,END_READING"]
        var reading = 1000.0
        for day in 1...30 {
            lines.append("1,\(String(format: "04/%02d/2026", day)),x,\(reading),\(reading + 40)")
            reading += 40
        }
        let result = try SmartMeterImport.read(lines.joined(separator: "\n"))
        XCTAssertEqual(result.monthlyKWh, [3: 1200])
    }

    func testBillingPeriodRowsCountAsWholeMonths() throws {
        let text = """
        ESIID,Start Date,End Date,Actual kWh,Metered kW
        1,01/05/2026,02/04/2026,1100,4.2
        1,02/05/2026,03/04/2026,950,3.9
        """
        let result = try SmartMeterImport.read(text)
        // Jan 5 – Feb 4 is mostly January; Feb 5 – Mar 4 is mostly February.
        XCTAssertEqual(result.monthlyKWh, [0: 1100, 1: 950])
    }

    func testTwoBillingPeriodsInOneMonthAreNotAddedTogether() throws {
        let text = """
        ESIID,Start Date,End Date,Actual kWh
        1,12/03/2025,01/02/2026,900
        1,01/03/2026,01/31/2026,1000
        1,02/01/2026,03/03/2026,800
        """
        let result = try SmartMeterImport.read(text)
        XCTAssertEqual(result.monthlyKWh, [11: 900, 0: 1000, 1: 800])
    }

    func testAGapInALongFileKeepsOnlyTheLastTwelveCalendarMonths() throws {
        // Jan–Dec 2024, then Mar–Jun 2025: the window is Jul 2024 – Jun 2025.
        let text = intervalFile(from: (2024, 1), months: 12, perInterval: 0.1) + "\n"
            + intervalFile(from: (2025, 3), months: 4, perInterval: 0.2).split(separator: "\n").dropFirst().joined(separator: "\n")
        let result = try SmartMeterImport.read(text)
        XCTAssertEqual(result.months.first, .init(year: 2024, month: 6))
        XCTAssertEqual(result.months.count, 10)
        XCTAssertEqual(result.monthlyKWh.count, 10)
        XCTAssertNil(result.monthlyKWh[0])   // January 2025 is missing, so it stays estimated
        XCTAssertEqual(result.monthlyKWh[2] ?? 0, 31 * 96 * 0.2, accuracy: 0.5)
    }

    func testTheRepeatedHourWhenDaylightSavingEndsCountsTwice() throws {
        var text = intervalFile(from: (2025, 11), months: 1, perInterval: 0.25)
        text += "\n'1,11/02/2025,11/02/2025 08:00:00,01:00,01:15,2,A,Consumption"
        let result = try SmartMeterImport.read(text)
        XCTAssertEqual(result.monthlyKWh[10], 30 * 96 * 0.25 + 2)
    }

    func testAMonthWithAFewDaysMissingIsScaledToTheWholeMonth() throws {
        var lines = ["ESIID,USAGE_DATE,REVISION_DATE,START_READING,END_READING"]
        for day in 1...28 { lines.append("1,\(String(format: "01/%02d/2026", day)),x,0,10") }
        let result = try SmartMeterImport.read(lines.joined(separator: "\n"))
        XCTAssertEqual(result.monthlyKWh, [0: 310])
    }

    func testOtherFilesAreRejected() {
        XCTAssertThrowsError(try SmartMeterImport.read("name,amount\nA,1")) { XCTAssertEqual($0 as? SmartMeterImport.Failure, .notASmartMeterFile) }
        XCTAssertThrowsError(try SmartMeterImport.read(header + "\n'1,03/01/2026,x,00:00,00:15,0.2,A,Consumption")) {
            XCTAssertEqual($0 as? SmartMeterImport.Failure, .noCompleteMonths)
        }
    }
}
