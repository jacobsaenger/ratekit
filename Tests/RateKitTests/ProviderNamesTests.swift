import XCTest
@testable import RateKit

final class ProviderNamesTests: XCTestCase {
    func testEveryProviderInTheExportHasABrandName() throws {
        let offers = PowerToChooseCSV.offers(try Fixtures.text("ptc-2026-10-20.csv"))
        for raw in Set(offers.map(\.provider)) {
            XCTAssertNotNil(ProviderNames.known[raw.uppercased()], raw)
        }
    }

    func testKnownAndFallbackNames() {
        XCTAssertEqual(ProviderNames.display("SMARTENERGY HOLDINGS LLC"), "SmartEnergy")
        XCTAssertEqual(ProviderNames.display("Octopus Energy LLC"), "Octopus Energy")
        XCTAssertEqual(ProviderNames.display("NEW SUNNY POWER LLC"), "New Sunny Power")
        XCTAssertEqual(ProviderNames.display("Brightside Energy, Inc."), "Brightside Energy")
    }
}
