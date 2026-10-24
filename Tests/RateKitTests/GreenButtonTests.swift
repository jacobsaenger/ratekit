import XCTest
@testable import RateKit

final class GreenButtonTests: XCTestCase {
    /// A minimal ESPI feed: consumption and (optionally) export reading types, one daily
    /// interval per day of the given month, `wh` watt-hours each (multiplier 0).
    func feed(year: Int, month: Int, wh: Double, export: Bool = false, linked: Bool = true) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        func readings(_ value: Double) -> String {
            (0..<days).map { d in
                let start = Int(first.timeIntervalSince1970) + d * 86400 + 3600
                return "<espi:IntervalReading><espi:timePeriod><espi:duration>86400</espi:duration><espi:start>\(start)</espi:start></espi:timePeriod><espi:value>\(Int(value))</espi:value></espi:IntervalReading>"
            }.joined()
        }
        let base = "https://services.smartmetertexas.net/espi/1_1/resource"
        func link(_ rel: String, _ href: String) -> String { linked ? "<link rel=\"\(rel)\" href=\"\(href)\"/>" : "" }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:espi="http://naesb.org/espi">
        <entry>\(link("self", "\(base)/ReadingType/1"))<content><espi:ReadingType><espi:flowDirection>1</espi:flowDirection><espi:powerOfTenMultiplier>0</espi:powerOfTenMultiplier><espi:uom>72</espi:uom></espi:ReadingType></content></entry>
        <entry>\(link("self", "\(base)/Subscription/1/UsagePoint/1/MeterReading/1"))\(link("related", "\(base)/ReadingType/1"))<content><espi:MeterReading/></content></entry>
        <entry>\(link("self", "\(base)/Subscription/1/UsagePoint/1/MeterReading/1/IntervalBlock/1"))\(link("up", "\(base)/Subscription/1/UsagePoint/1/MeterReading/1/IntervalBlock"))<content><espi:IntervalBlock>\(readings(wh))</espi:IntervalBlock></content></entry>
        """
        if export {
            out += """
            <entry>\(link("self", "\(base)/ReadingType/2"))<content><espi:ReadingType><espi:flowDirection>19</espi:flowDirection><espi:powerOfTenMultiplier>0</espi:powerOfTenMultiplier><espi:uom>72</espi:uom></espi:ReadingType></content></entry>
            <entry>\(link("self", "\(base)/Subscription/1/UsagePoint/1/MeterReading/2"))\(link("related", "\(base)/ReadingType/2"))<content><espi:MeterReading/></content></entry>
            <entry>\(link("self", "\(base)/Subscription/1/UsagePoint/1/MeterReading/2/IntervalBlock/1"))\(link("up", "\(base)/Subscription/1/UsagePoint/1/MeterReading/2/IntervalBlock"))<content><espi:IntervalBlock>\(readings(9000))</espi:IntervalBlock></content></entry>
            """
        }
        return out + "\n</feed>"
    }

    func testDailyWattHoursBecomeMonthlyKWh() throws {
        let result = try SmartMeterImport.read(feed(year: 2026, month: 4, wh: 40000))
        XCTAssertEqual(result.monthlyKWh, [3: 1200])
        XCTAssertFalse(result.skippedSurplus)
    }

    func testExportedSolarIsLeftOut() throws {
        let result = try SmartMeterImport.read(feed(year: 2026, month: 4, wh: 40000, export: true))
        XCTAssertEqual(result.monthlyKWh, [3: 1200])
        XCTAssertTrue(result.skippedSurplus)
    }

    func testAFileWithoutLinksUsesItsOnlyReadingType() throws {
        let result = try SmartMeterImport.read(feed(year: 2026, month: 4, wh: 40000, linked: false))
        XCTAssertEqual(result.monthlyKWh, [3: 1200])
    }

    func testAnUnlinkedFileWithSolarExportIsNotGuessed() {
        XCTAssertThrowsError(try SmartMeterImport.read(feed(year: 2026, month: 4, wh: 40000, export: true, linked: false)))
    }

    /// Two consumption series for the same days (15-minute and daily, here both daily).
    func doubleSeries() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let first = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let readings = (0..<30).map { d in
            "<espi:IntervalReading><espi:timePeriod><espi:duration>86400</espi:duration><espi:start>\(Int(first.timeIntervalSince1970) + d * 86400 + 3600)</espi:start></espi:timePeriod><espi:value>40000</espi:value></espi:IntervalReading>"
        }.joined()
        let base = "https://x/espi/1_1/resource"
        var out = "<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:espi=\"http://naesb.org/espi\">"
        out += "<entry><link rel=\"self\" href=\"\(base)/ReadingType/1\"/><content><espi:ReadingType><espi:flowDirection>1</espi:flowDirection><espi:powerOfTenMultiplier>0</espi:powerOfTenMultiplier><espi:uom>72</espi:uom></espi:ReadingType></content></entry>"
        for n in [1, 10] {
            out += "<entry><link rel=\"self\" href=\"\(base)/UsagePoint/1/MeterReading/\(n)\"/><link rel=\"related\" href=\"\(base)/ReadingType/1\"/><content><espi:MeterReading/></content></entry>"
            out += "<entry><link rel=\"up\" href=\"\(base)/UsagePoint/1/MeterReading/\(n)/IntervalBlock\"/><content><espi:IntervalBlock>\(readings)</espi:IntervalBlock></content></entry>"
        }
        return out + "</feed>"
    }

    func testTheSameUsageInTwoSeriesIsCountedOnce() throws {
        // Meter readings 1 and 10 also check that /MeterReading/1 doesn't claim /10's blocks.
        XCTAssertEqual(try SmartMeterImport.read(doubleSeries()).monthlyKWh, [3: 1200])
    }

    func testRunningMeterTotalsAreNotUsage() {
        let text = feed(year: 2026, month: 4, wh: 40000)
            .replacingOccurrences(of: "<espi:uom>72</espi:uom>", with: "<espi:accumulationBehaviour>1</espi:accumulationBehaviour><espi:uom>72</espi:uom>")
        XCTAssertThrowsError(try SmartMeterImport.read(text))
    }

    func testOtherXMLIsRejected() {
        XCTAssertThrowsError(try SmartMeterImport.read("<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><title>x</title></entry></feed>"))
    }
}
