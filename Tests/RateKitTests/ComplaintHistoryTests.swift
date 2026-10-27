import XCTest
@testable import RateKit

final class ComplaintHistoryTests: XCTestCase {
    /// SmartEnergy's page as Power to Choose served it on 2026-10-27.
    func testReadsThePowerToChoosePage() throws {
        let history = try XCTUnwrap(ComplaintHistory.parse(html: try Fixtures.text("complaints/smartenergy.html")))
        XCTAssertEqual(history.period, "Apr 2026 to Oct 2026")
        XCTAssertEqual(history.counts["Provision Of Service"], 6)
        XCTAssertEqual(history.counts["Billing"], 1)
        XCTAssertEqual(history.counts["Slamming"], 0)
        XCTAssertEqual(history.counts.count, 7)
        XCTAssertEqual(history.total, 8)
        XCTAssertEqual(history.types.map(\.name), ["Provision Of Service", "Billing", "Discontinuance"])
    }

    /// The page without its company code has an empty chart: nothing is read.
    func testEmptyPageIsNotRead() {
        XCTAssertNil(ComplaintHistory.parse(html: "Period: to </div> var chartData = ; var maxValue = 0;"))
        XCTAssertNil(ComplaintHistory.parse(html: "<html>No data</html>"))
    }
}
