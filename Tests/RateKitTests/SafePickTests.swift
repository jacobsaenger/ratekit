import XCTest
@testable import RateKit

final class SafePickTests: XCTestCase {
    let flat = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))

    func plan(_ id: String, _ terms: PlanTerms) -> FeedPlan {
        FeedPlan(offer: PlanOffer(id: id, tdu: .oncor, provider: "P\(id)", product: id, price500: 0, price1000: 0, price2000: 0),
                 status: .verified, terms: terms)
    }

    func testScaledUsageRoundsToWholeKWh() {
        XCTAssertEqual(flat.scaled(by: 0.8).kWh.first, 800)
        XCTAssertEqual(YearOfUsage(kWh: Array(repeating: 1157, count: 12), estimated: Array(repeating: true, count: 12)).scaled(by: 1.3).kWh.first, 1504)
    }

    func testSafePickCanDifferFromTheCheapest() throws {
        // Credit plan: 13¢ with $85 off at 1,000 kWh or more. Plain plan: 8¢. Delivery is Oncor's.
        // At 1,000 kWh: credit $117.73 vs plain $152.73 a month, so the credit plan is cheapest.
        // At 800 kWh the credit plan misses the credit: $165.00 vs $123.00, $504 a year worse.
        // At 1,300 kWh: credit $177.33 vs plain $197.33, plain is $240 a year worse.
        let credit = PlanTerms(energyRate: 13, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
                               credits: [UsageCredit(amount: 85, minKWh: 1000)])
        let plain = PlanTerms(energyRate: 8, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [plan("credit", credit), plan("plain", plain)])

        XCTAssertEqual(PlanRanking(feed: feed, tdu: .oncor, usage: flat).ranked.first?.id, "credit")
        let pick = try XCTUnwrap(SafePick(feed: feed, tdu: .oncor, usage: flat))
        XCTAssertEqual(pick.planID, "plain")
        XCTAssertEqual(pick.worstExtra, 12 * 35, accuracy: 0.01)   // $35 a month behind at today's usage
    }

    func testNoPlansNoPick() {
        XCTAssertNil(SafePick(feed: Feed(generatedAt: Date(), plans: []), tdu: .oncor, usage: flat))
    }
}
