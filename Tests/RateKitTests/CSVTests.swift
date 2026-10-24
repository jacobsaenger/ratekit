import XCTest
@testable import RateKit

final class CSVTests: XCTestCase {
    func testQuotedFieldsKeepCommasQuotesAndLineBreaks() {
        let rows = CSV.rows("a,\"b, c\",\"say \"\"hi\"\"\"\r\n\"line\nbreak\",2,3\n")
        XCTAssertEqual(rows, [["a", "b, c", "say \"hi\""], ["line\nbreak", "2", "3"]])
    }

    func testPowerToChooseExportOfferCounts() throws {
        let offers = PowerToChooseCSV.offers(try Fixtures.text("ptc-2026-10-20.csv"))
        // 931 English rows on 2026-10-20; the export's last line is "END OF FILE".
        XCTAssertEqual(offers.count, 931)
        XCTAssertEqual(Set(offers.map(\.provider)).count, 44)
        XCTAssertEqual(Set(offers.map(\.tdu)), Set(TDU.allCases))
    }

    func testPowerToChooseRowIsTyped() throws {
        let offers = PowerToChooseCSV.offers(try Fixtures.text("ptc-2026-10-20.csv"))
        let plan = try XCTUnwrap(offers.first { $0.id == "33364" })
        XCTAssertEqual(plan.provider, "AP GAS & ELECTRIC (TX) LLC")
        XCTAssertEqual(plan.product, "SimpleSaver 12")
        XCTAssertEqual(plan.tdu, .oncor)
        XCTAssertEqual(plan.price500, 19.8, accuracy: 0.0001)
        XCTAssertEqual(plan.price1000, 6.9, accuracy: 0.0001)
        XCTAssertEqual(plan.price2000, 12.9, accuracy: 0.0001)
        XCTAssertEqual(plan.termMonths, 12)
        XCTAssertTrue(plan.fixedRate)
        XCTAssertFalse(plan.timeOfUse)
        XCTAssertTrue(plan.factsURL.hasPrefix("https://"))
    }
}
