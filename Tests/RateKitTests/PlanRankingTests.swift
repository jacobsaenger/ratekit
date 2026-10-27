import XCTest
@testable import RateKit

final class PlanRankingTests: XCTestCase {
    func plan(_ id: String, tdu: TDU = .oncor, status: PlanStatus = .verified, terms: PlanTerms?,
              term: Int = 12, fixed: Bool = true, prepaid: Bool = false, p1000: Double = 15) -> FeedPlan {
        FeedPlan(
            offer: PlanOffer(id: id, tdu: tdu, provider: "P\(id)", product: "Plan \(id)",
                             price500: 15, price1000: p1000, price2000: 15,
                             prepaid: prepaid, fixedRate: fixed, termMonths: term),
            status: status, terms: terms
        )
    }

    let flat = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))

    func testRanksByYearlyCostForThisHousehold() throws {
        // At 1,000 kWh every month the credit plan wins; at 700 kWh it never gets the credit.
        let credit = PlanTerms(energyRate: 12, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
                               credits: [UsageCredit(amount: 125, minKWh: 1000)])
        let plain = PlanTerms(energyRate: 8, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [plan("a", terms: plain), plan("b", terms: credit)])

        XCTAssertEqual(PlanRanking(feed: feed, tdu: .oncor, usage: flat).ranked.map(\.id), ["b", "a"])

        let small = YearOfUsage(kWh: Array(repeating: 700, count: 12), estimated: Array(repeating: false, count: 12))
        let ranking = PlanRanking(feed: feed, tdu: .oncor, usage: small)
        XCTAssertEqual(ranking.ranked.map(\.id), ["a", "b"])
        // 700 kWh × 14.8673¢ = $104.07 + $4.06 = $108.13 a month.
        let first = try XCTUnwrap(ranking.ranked.first)
        XCTAssertEqual(first.annualCost, 12 * 108.1311, accuracy: 0.001)
        XCTAssertEqual(first.averagePrice, 108.1311 / 700 * 100, accuracy: 0.0001)
        XCTAssertEqual(first.monthlyBills.count, 12)
    }

    /// A 3-month teaser at 6¢ isn't a year at 6¢: from November its three months are
    /// November–January, and February–October are priced on the cheapest 12-month plan.
    func testShortPlanSwitchesAgainWhenItEnds() throws {
        let teaser = PlanTerms(energyRate: 6, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let year = PlanTerms(energyRate: 9, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let dearer = PlanTerms(energyRate: 10, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [
            plan("t", terms: teaser, term: 3), plan("y", terms: year), plan("z", terms: dearer, term: 24),
            plan("v", terms: teaser, term: 1, fixed: false),
        ])
        var filters = PlanFilters()
        filters.term = .any
        let ranking = PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: filters, startMonth: 11)
        let t = try XCTUnwrap(ranking.ranked.first { $0.id == "t" })
        let monthT = 1000 * 12.8673 / 100 + 4.06, monthY = 1000 * 15.8673 / 100 + 4.06
        XCTAssertEqual(t.annualCost, 3 * monthT + 9 * monthY, accuracy: 0.001)
        XCTAssertEqual(t.afterTerm?.plan.id, "y")
        XCTAssertEqual(t.afterTerm?.months, 9)
        XCTAssertEqual(t.afterTerm?.cost ?? 0, 9 * monthY, accuracy: 0.001)
        // November, December and January are the teaser's; February is the next plan's.
        XCTAssertEqual(t.monthlyBills[10], monthT, accuracy: 0.001)
        XCTAssertEqual(t.monthlyBills[0], monthT, accuracy: 0.001)
        XCTAssertEqual(t.monthlyBills[1], monthY, accuracy: 0.001)
        // A 12-month plan and a variable month-to-month plan are priced on their own rate.
        XCTAssertNil(ranking.ranked.first { $0.id == "y" }?.afterTerm)
        XCTAssertNil(ranking.ranked.first { $0.id == "v" }?.afterTerm)
        XCTAssertEqual(feed.monthToMonthPlans(provider: "Pv", tdu: .oncor).map(\.id), ["v"])
        XCTAssertEqual(feed.monthToMonthPlans(provider: "Pt", tdu: .oncor), [])
    }

    /// Simple plans only: one fixed energy price, nothing that changes with usage or how you
    /// pay. Picking providers keeps just theirs.
    /// Each plan's one-time fee is paid once: the short plan's in its first month, the next
    /// plan's when switching to it.
    func testShortPlanAndNextPlanFeesArePaidOnce() throws {
        var teaser = PlanTerms(energyRate: 6, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        teaser.oneTimeFee = 49.99
        var year = PlanTerms(energyRate: 9, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        year.oneTimeFee = 20
        let feed = Feed(generatedAt: Date(), plans: [plan("t", terms: teaser, term: 3), plan("y", terms: year)])
        var filters = PlanFilters()
        filters.term = .any
        let t = try XCTUnwrap(PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: filters, startMonth: 11).ranked.first { $0.id == "t" })
        let monthT = 1000 * 12.8673 / 100 + 4.06, monthY = 1000 * 15.8673 / 100 + 4.06
        XCTAssertEqual(t.annualCost, 3 * monthT + 49.99 + 9 * monthY + 20, accuracy: 0.001)
        XCTAssertEqual(t.monthlyBills[10], monthT + 49.99, accuracy: 0.001)
        XCTAssertEqual(t.monthlyBills[1], monthY + 20, accuracy: 0.001)
        XCTAssertEqual(t.afterTerm?.signUpFee, 20)
        XCTAssertNil(t.afterTerm?.terms.oneTimeFee)
    }

    /// Providers chosen in another area don't empty this one's list.
    func testProvidersFromAnotherAreaAreIgnored() {
        let terms = PlanTerms(energyRate: 9, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [plan("a", terms: terms), plan("b", tdu: .centerPoint, terms: terms)])
        var filters = PlanFilters()
        filters.providers = ["Pb"]
        XCTAssertEqual(PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: filters).ranked.map(\.id), ["a"])
    }

    func testSimplePlansAndChosenProviders() {
        let plain = PlanTerms(energyRate: 9, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let credit = PlanTerms(energyRate: 12, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
                               credits: [UsageCredit(amount: 100, minKWh: 1000)])
        var tiered = plain
        tiered.energyTiers = [EnergyTier(fromKWh: 0, rate: 9), EnergyTier(fromKWh: 1000, rate: 12)]
        var setup = plain
        setup.oneTimeFee = 49.99
        var autopay = plan("pay", terms: plain)
        autopay.payment = PaymentRequirement(autopay: true, paperless: false, feeIfNot: 5)
        let feed = Feed(generatedAt: Date(), plans: [
            plan("plain", terms: plain), plan("credit", terms: credit), plan("tiered", terms: tiered),
            plan("setup", terms: setup), autopay, plan("var", terms: plain, fixed: false),
            plan("pre", terms: plain, prepaid: true), plan("unchecked", status: .estimated(reason: "x"), terms: nil),
        ])
        var filters = PlanFilters()
        filters.simplePlansOnly = true
        let ranking = PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: filters)
        XCTAssertEqual(ranking.ranked.map(\.id), ["plain"])
        XCTAssertEqual(ranking.estimated, [])

        filters = PlanFilters()
        filters.providers = ["Pcredit", "Ptiered"]
        XCTAssertEqual(Set(PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: filters).ranked.map(\.id)), ["credit", "tiered"])
    }

    func testOnlyThisAreaAndSplitByStatus() {
        let terms = PlanTerms(energyRate: 8, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [
            plan("a", terms: terms),
            plan("b", tdu: .centerPoint, terms: terms),
            plan("c", status: .estimated(reason: "prices do not match"), terms: nil, p1000: 12),
            plan("d", status: .estimated(reason: "label download failed"), terms: nil, p1000: 10),
            plan("e", status: .timeOfUse, terms: nil),
        ])
        var all = PlanFilters(); all.term = .any
        let ranking = PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: all)
        XCTAssertEqual(ranking.ranked.map(\.id), ["a"])
        XCTAssertEqual(ranking.estimated.map(\.id), ["d", "c"])
        XCTAssertEqual(ranking.timeOfUse.map(\.id), ["e"])
    }

    func testFilters() {
        let terms = PlanTerms(energyRate: 8, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let fee = PlanTerms(energyRate: 7, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
                            minimumUsageFees: [MinimumUsageFee(amount: 9.95, belowKWh: 1000)])
        let feed = Feed(generatedAt: Date(), plans: [
            plan("short", terms: terms, term: 3),
            plan("year", terms: terms, term: 12),
            plan("variable", terms: terms, term: 1, fixed: false),
            plan("prepaid", terms: terms, term: 12, prepaid: true),
            plan("fee", terms: fee, term: 24),
        ])
        var f = PlanFilters()
        f.term = .from7to12
        XCTAssertEqual(Set(PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: f).ranked.map(\.id)), ["year", "prepaid"])
        f = PlanFilters(); f.term = .any; f.fixedRateOnly = true; f.hidePrepaid = true; f.hideMinimumUsageFees = true
        XCTAssertEqual(Set(PlanRanking(feed: feed, tdu: .oncor, usage: flat, filters: f).ranked.map(\.id)), ["short", "year"])
        // The default hides plans shorter than a year.
        XCTAssertEqual(Set(PlanRanking(feed: feed, tdu: .oncor, usage: flat).ranked.map(\.id)), ["year", "prepaid", "fee"])
    }

    func testPricesWithTheTDUsCurrentDeliveryCharges() throws {
        // A label printing CenterPoint's older 6.413¢ is priced at today's 6.5333¢ + $4.90.
        let stale = PlanTerms(energyRate: 4.997, deliveryPerKWh: 6.413, deliveryPerMonth: 4.90)
        let bundled = PlanTerms(energyRate: 12.7, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let feed = Feed(generatedAt: Date(), plans: [plan("a", tdu: .centerPoint, terms: stale),
                                                     plan("b", tdu: .centerPoint, terms: bundled)])
        let ranking = PlanRanking(feed: feed, tdu: .centerPoint, usage: flat)
        let a = try XCTUnwrap(ranking.ranked.first { $0.id == "a" })
        XCTAssertEqual(a.terms.deliveryPerKWh, 6.5333)
        XCTAssertEqual(a.annualCost, 12 * (1000 * (4.997 + 6.5333) / 100 + 4.90), accuracy: 0.001)
        // Delivery already inside the energy charge stays that way.
        let b = try XCTUnwrap(ranking.ranked.first { $0.id == "b" })
        XCTAssertEqual(b.terms.deliveryPerKWh, 0)
    }

    func testDeliveryChargesComeFromTheFeed() throws {
        let terms = PlanTerms(energyRate: 5, deliveryPerKWh: 6.5333, deliveryPerMonth: 4.90)
        var feed = Feed(generatedAt: Date(), plans: [plan("a", tdu: .centerPoint, terms: terms)])
        feed.deliveryCharges?["centerPoint"] = TDUCharges(perKWh: 7.0, perMonth: 5.0)
        let a = try XCTUnwrap(PlanRanking(feed: feed, tdu: .centerPoint, usage: flat).ranked.first)
        XCTAssertEqual(a.terms.deliveryPerKWh, 7.0)
        XCTAssertEqual(a.annualCost, 12 * (1000 * 12.0 / 100 + 5.0), accuracy: 0.001)
        // A feed from before the table was added uses the app's own table.
        feed.deliveryCharges = nil
        XCTAssertEqual(feed.delivery(for: .centerPoint), TDUCharges.current(.centerPoint))
    }
}
