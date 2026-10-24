import XCTest
@testable import RateKit

/// Expected answers checked against ERCOT's meter counts (full extract of 2026-10-05).
final class ServiceAreaTests: XCTestCase {
    func testCities() {
        XCTAssertEqual(ServiceArea.lookup("77002"), .single(.centerPoint))   // Houston
        XCTAssertEqual(ServiceArea.lookup("75201"), .single(.oncor))         // Dallas
        XCTAssertEqual(ServiceArea.lookup("79401"), .single(.lubbock))       // Lubbock
        XCTAssertEqual(ServiceArea.lookup("78401"), .single(.aepCentral))    // Corpus Christi
        XCTAssertEqual(ServiceArea.lookup("76901"), .single(.aepNorth))      // San Angelo
        XCTAssertEqual(ServiceArea.lookup("77550"), .single(.centerPoint))   // Galveston
    }

    func testCityUtilityAreasHaveNoChoice() {
        XCTAssertEqual(ServiceArea.lookup("78701"), .noChoice)   // Austin Energy
        XCTAssertEqual(ServiceArea.lookup("78205"), .noChoice)   // CPS Energy, San Antonio
        XCTAssertEqual(ServiceArea.lookup("79901"), .noChoice)   // El Paso Electric
    }

    func testSplitZIPListsLargestShareFirst() {
        // Farmersville: about 2,400 active homes each on Oncor and TNMP.
        XCTAssertEqual(ServiceArea.lookup("75442"), .split([.oncor, .tnmp]))
    }

    func testNotTexas() {
        XCTAssertEqual(ServiceArea.lookup("10001"), .notTexas)
        XCTAssertEqual(ServiceArea.lookup("7700"), .notTexas)
        XCTAssertEqual(ServiceArea.lookup("abcde"), .notTexas)
    }

    func testBundledTableCoversEveryCompetitiveTDUWithHomes() {
        let tdus = Set(ZIPTable.bundled.zips.values.flatMap { $0 })
        XCTAssertEqual(tdus, [.oncor, .centerPoint, .aepCentral, .aepNorth, .tnmp, .lubbock, .nueces])
        XCTAssertGreaterThan(ZIPTable.bundled.zips.count, 1000)
    }
}
