import XCTest
@testable import RateKit

final class ReferralFeeTests: XCTestCase {
    func testFeedSaysWhoPaysUs() throws {
        var feed = Feed(generatedAt: Date(timeIntervalSince1970: 0), plans: [])
        XCTAssertNil(feed.referralFee(for: "Reliant"))
        feed.referralFees = ["Gexa Energy": "$40 per sign-up"]
        let decoded = try Feed.decode(feed.encoded())
        XCTAssertEqual(decoded.referralFee(for: "Gexa Energy"), "$40 per sign-up")
        XCTAssertNil(decoded.referralFee(for: "Reliant"))
    }

    func testReferralFeesNeverChangeTheRanking() {
        func plan(_ id: String, _ provider: String, status: PlanStatus = .verified, rate: Double? = nil,
                  p1000: Double = 15) -> FeedPlan {
            FeedPlan(
                offer: PlanOffer(id: id, tdu: .oncor, provider: provider, product: "Plan \(id)",
                                 price500: 15, price1000: p1000, price2000: 15,
                                 prepaid: false, fixedRate: true, termMonths: 12),
                status: status,
                terms: rate.map { PlanTerms(energyRate: $0, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06) }
            )
        }
        // The paying providers lose on cost and on the provider-name tie-break, so anything
        // that favoured them would move them up.
        let unpaid = Feed(generatedAt: Date(timeIntervalSince1970: 0), plans: [
            plan("dear", "Gexa Energy", rate: 11),
            plan("tieZ", "Zulu Energy", rate: 9),
            plan("tieB", "Bravo Energy", rate: 9),
            plan("cheap", "Alpha Power", rate: 8),
            plan("estPaid", "Gexa Energy", status: .estimated(reason: "prices do not match"), p1000: 12),
            plan("estFree", "Alpha Power", status: .estimated(reason: "prices do not match"), p1000: 10),
            plan("tou", "Zulu Energy", status: .timeOfUse),
        ])
        var paid = unpaid
        paid.referralFees = ["Gexa Energy": "$200 per sign-up", "Zulu Energy": "$50 per sign-up"]

        let small = YearOfUsage(kWh: Array(repeating: 700, count: 12), estimated: Array(repeating: false, count: 12))
        let flat = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
        for usage in [small, flat] {
            let without = PlanRanking(feed: unpaid, tdu: .oncor, usage: usage)
            let with = PlanRanking(feed: paid, tdu: .oncor, usage: usage)
            XCTAssertEqual(with, without)
            XCTAssertEqual(with.ranked.map(\.id), ["cheap", "tieB", "tieZ", "dear"])
            XCTAssertEqual(with.estimated.map(\.id), ["estFree", "estPaid"])
            XCTAssertEqual(with.timeOfUse.map(\.id), ["tou"])
        }
    }
}
