import XCTest
@testable import RateKit

final class FeedTests: XCTestCase {
    func testRoundTrip() throws {
        let offer = PlanOffer(id: "1", tdu: .oncor, provider: "P", product: "Plan", price500: 19.8, price1000: 6.9, price2000: 12.9)
        let terms = PlanTerms(energyRate: 12.127, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
                              credits: [UsageCredit(amount: 125, minKWh: 1000)])
        let feed = Feed(generatedAt: Date(timeIntervalSince1970: 1_792_000_000), plans: [
            FeedPlan(offer: offer, status: .verified, terms: terms),
            FeedPlan(offer: offer, status: .estimated(reason: "prices do not match"), terms: nil),
            FeedPlan(offer: offer, status: .timeOfUse, terms: nil),
        ])
        let decoded = try Feed.decode(try feed.encoded())
        XCTAssertEqual(decoded, feed)
        XCTAssertEqual(decoded.schemaVersion, Feed.currentSchemaVersion)
        XCTAssertEqual(decoded.market, "TX")
    }

    func testRefreshAtMostOnceADay() {
        let built = Date(timeIntervalSince1970: 1_792_000_000)
        let feed = Feed(generatedAt: built, plans: [])
        XCTAssertFalse(feed.isDueForRefresh(now: built.addingTimeInterval(19 * 3600)))
        XCTAssertTrue(feed.isDueForRefresh(now: built.addingTimeInterval(20 * 3600)))
        XCTAssertTrue(feed.isDueForRefresh(now: built.addingTimeInterval(3 * 86400)))
    }
}
