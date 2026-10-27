import XCTest
@testable import RateKit

final class ContractTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func plan(ends: Date, fee: Double = 150) -> CurrentPlan {
        CurrentPlan(providerName: "Reliant", planName: "Secure Advantage 12", endDate: ends, cancelFee: fee,
                    energyRate: 14, baseCharge: 0)
    }

    // MARK: Reminders

    func testRemindersAt60_30And14DaysBefore() {
        let reminders = ReminderPlanner.reminders(for: plan(ends: date(2027, 3, 31)), now: date(2026, 10, 20), calendar: calendar)
        XCTAssertEqual(reminders.map(\.daysBefore), [60, 30, 14])
        XCTAssertEqual(reminders.map(\.date), [date(2027, 1, 30, 9), date(2027, 3, 1, 9), date(2027, 3, 17, 9)])
        XCTAssertTrue(reminders[2].body.contains("without a cancellation fee"))
        XCTAssertEqual(reminders[0].title, "Your Secure Advantage 12 plan ends soon")
    }

    func testPastRemindersAreSkipped() {
        // 20 days left: only the 14-day reminder is still ahead.
        let reminders = ReminderPlanner.reminders(for: plan(ends: date(2026, 11, 9)), now: date(2026, 10, 20), calendar: calendar)
        XCTAssertEqual(reminders.map(\.daysBefore), [14])
        XCTAssertTrue(ReminderPlanner.reminders(for: plan(ends: date(2026, 10, 1)), now: date(2026, 10, 20), calendar: calendar).isEmpty)
    }

    // MARK: Current plan terms

    func testTypedPlanUsesCurrentDelivery() throws {
        let terms = try XCTUnwrap(plan(ends: date(2027, 1, 1)).terms(tdu: .oncor, feed: nil))
        XCTAssertEqual(terms.energyTiers, [EnergyTier(fromKWh: 0, rate: 14)])
        XCTAssertEqual(terms.deliveryPerKWh, 6.8673)
        XCTAssertEqual(terms.deliveryPerMonth, 4.06)
    }

    func testAllInRateGetsNoDeliveryAdded() throws {
        var p = plan(ends: date(2027, 1, 1))
        p.includesDelivery = true
        let terms = try XCTUnwrap(p.terms(tdu: .oncor, feed: nil))
        XCTAssertEqual(terms.deliveryPerKWh, 0)
        XCTAssertEqual(terms.deliveryPerMonth, 0)
    }

    func testOlderSavedPlanWithoutTheDeliveryFlagStillDecodes() throws {
        let json = #"{"providerName":"Reliant","planName":"","endDate":0,"cancelFee":0,"energyRate":14,"baseCharge":0}"#
        let decoded = try JSONDecoder().decode(CurrentPlan.self, from: Data(json.utf8))
        XCTAssertNil(decoded.includesDelivery)
        XCTAssertNil(decoded.renewalEnergyRate)
    }

    func testFeedPlanNoLongerListed() {
        var p = plan(ends: date(2027, 1, 1))
        p.feedPlanID = "gone"
        XCTAssertNil(p.terms(tdu: .oncor, feed: Feed(generatedAt: Date(), plans: [])))
    }

    // MARK: Switching and alerts

    func comparison(now: Date, fee: Double = 150) throws -> SwitchComparison {
        let cheap = PlanTerms(energyRate: 6, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [FeedPlan(
            offer: PlanOffer(id: "b", tdu: .oncor, provider: "P", product: "Cheap 12", price500: 0, price1000: 0, price2000: 0),
            status: .verified, terms: cheap)])
        let usage = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
        let current = plan(ends: date(2027, 3, 31), fee: fee)
        let terms = try XCTUnwrap(current.terms(tdu: .oncor, feed: feed))
        return try XCTUnwrap(SwitchComparison(current: current, terms: terms, usage: usage,
                                              ranking: PlanRanking(feed: feed, tdu: .oncor, usage: usage),
                                              now: now, calendar: calendar))
    }

    func testSavingCountsTheCancellationFeeOnlyBeforeTheFeeFreeWindow() throws {
        // 14¢ vs 6¢ energy at 12,000 kWh: $960 a year.
        let early = try comparison(now: date(2026, 10, 20))
        XCTAssertEqual(early.annualSaving, 960, accuracy: 0.001)
        XCTAssertEqual(early.cancelFeeNow, 150)
        XCTAssertEqual(early.netFirstYearSaving, 810, accuracy: 0.001)
        // 14 days before the end date the fee no longer applies.
        XCTAssertEqual(try comparison(now: date(2027, 3, 17)).cancelFeeNow, 0)
    }

    func testAlertNeedsTheThresholdAndAWeekSinceTheLastOne() throws {
        let c = try comparison(now: date(2026, 10, 20))
        let now = date(2026, 10, 20)
        XCTAssertTrue(AlertPlanner.shouldAlert(c, threshold: 100, lastAlert: nil, now: now))
        XCTAssertFalse(AlertPlanner.shouldAlert(c, threshold: 900, lastAlert: nil, now: now))
        XCTAssertFalse(AlertPlanner.shouldAlert(c, threshold: 100, lastAlert: date(2026, 10, 15), now: now))
        XCTAssertTrue(AlertPlanner.shouldAlert(c, threshold: 100, lastAlert: date(2026, 10, 13, 11), now: now))
    }

    // MARK: Switch now or wait

    let flatYear = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
    let current14 = PlanTerms(energyRate: 14, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)   // $212.733 a month
    let best6 = PlanTerms(energyRate: 6, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)        // $132.733 a month

    func bestPlan() -> PricedPlan {
        let feed = Feed(generatedAt: Date(), plans: [FeedPlan(
            offer: PlanOffer(id: "b", tdu: .oncor, provider: "P", product: "Cheap 12", price500: 0, price1000: 0, price2000: 0),
            status: .verified, terms: best6)])
        return PlanRanking(feed: feed, tdu: .oncor, usage: flatYear).ranked[0]
    }

    func testDailyCostingAddsUpToWholeMonths() {
        // Jan 1 to Jan 16 is 15 of January's 31 days.
        let half = CostEngine.cost(current14, monthlyKWh: flatYear.kWh, from: date(2027, 1, 1), to: date(2027, 1, 16), calendar: calendar)
        XCTAssertEqual(half, 212.733 * 15 / 31, accuracy: 0.001)
        let year = CostEngine.cost(current14, monthlyKWh: flatYear.kWh, from: date(2027, 1, 1), to: date(2028, 1, 1), calendar: calendar)
        XCTAssertEqual(year, 12 * 212.733, accuracy: 0.001)
    }

    func testSwitchNowWhenTheFeeFreeWindowIsFarOff() throws {
        // Ends Apr 15, so fees stop Apr 1. Waiting costs 3 months × $80 = $240, more than the $150 fee.
        let plan = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 4, 15), cancelFee: 150, energyRate: 14)
        let timing = try XCTUnwrap(SwitchTiming(current: plan, currentTerms: current14, best: bestPlan(),
                                                usage: flatYear, now: date(2027, 1, 1), calendar: calendar))
        XCTAssertEqual(timing.feeFreeDate, date(2027, 4, 1, 0))
        XCTAssertEqual(timing.switchNowSaving, 810, accuracy: 0.01)   // 12 × $80 − $150
        XCTAssertEqual(timing.waitSaving, 720, accuracy: 0.01)        // 9 × $80
        XCTAssertFalse(timing.waitIsBetter)
    }

    func testWaitWhenTheFeeFreeWindowIsClose() throws {
        // Ends Feb 15, so fees stop Feb 1. One more month costs $80, less than the $150 fee.
        let plan = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 2, 15), cancelFee: 150, energyRate: 14)
        let timing = try XCTUnwrap(SwitchTiming(current: plan, currentTerms: current14, best: bestPlan(),
                                                usage: flatYear, now: date(2027, 1, 1), calendar: calendar))
        XCTAssertEqual(timing.switchNowSaving, 810, accuracy: 0.01)
        XCTAssertEqual(timing.waitSaving, 880, accuracy: 0.01)        // 11 × $80
        XCTAssertTrue(timing.waitIsBetter)
    }

    /// A best plan with a $60 sign-up fee pays it once in either path, not spread over
    /// the months after the switch.
    func testSignUpFeeIsPaidOnceWhicheverDayYouSwitch() throws {
        var terms = best6
        terms.oneTimeFee = 60
        let feed = Feed(generatedAt: Date(), plans: [FeedPlan(
            offer: PlanOffer(id: "b", tdu: .oncor, provider: "P", product: "Cheap 12", price500: 0, price1000: 0, price2000: 0),
            status: .verified, terms: terms)])
        let best = PlanRanking(feed: feed, tdu: .oncor, usage: flatYear).ranked[0]
        let plan = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 4, 15), cancelFee: 150, energyRate: 14)
        let timing = try XCTUnwrap(SwitchTiming(current: plan, currentTerms: current14, best: best,
                                                usage: flatYear, now: date(2027, 1, 1), calendar: calendar))
        XCTAssertEqual(timing.switchNowSaving, 810 - 60, accuracy: 0.01)
        XCTAssertEqual(timing.waitSaving, 720 - 60, accuracy: 0.01)
    }

    /// A 3-month top plan is priced for its three months, then on the plan the ranking
    /// switches to, so switch timing agrees with the yearly saving.
    func testSwitchTimingFollowsAShortTopPlanOntoItsNextPlan() throws {
        let teaser = PlanTerms(energyRate: 3, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let feed = Feed(generatedAt: Date(), plans: [
            FeedPlan(offer: PlanOffer(id: "t", tdu: .oncor, provider: "T", product: "Teaser 3", price500: 0, price1000: 0,
                                      price2000: 0, termMonths: 3), status: .verified, terms: teaser),
            FeedPlan(offer: PlanOffer(id: "b", tdu: .oncor, provider: "P", product: "Cheap 12", price500: 0, price1000: 0,
                                      price2000: 0), status: .verified, terms: best6),
        ])
        var filters = PlanFilters()
        filters.term = .any
        let best = try XCTUnwrap(PlanRanking(feed: feed, tdu: .oncor, usage: flatYear, filters: filters, startMonth: 1).ranked.first)
        XCTAssertEqual(best.id, "t")
        let plan = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 4, 15), cancelFee: 150, energyRate: 14)
        let timing = try XCTUnwrap(SwitchTiming(current: plan, currentTerms: current14, best: best,
                                                usage: flatYear, now: date(2027, 1, 1), calendar: calendar))
        // Today: 3 months at $110 a month less, then 9 at $80 less (the 12-month plan), minus the fee.
        XCTAssertEqual(timing.switchNowSaving, 3 * 110 + 9 * 80 - 150, accuracy: 0.01)
        // Waiting to Apr 1: Apr–Jun on the teaser, Jul–Dec on the 12-month plan.
        XCTAssertEqual(timing.waitSaving, 3 * 110 + 6 * 80, accuracy: 0.01)
    }

    /// Once it's the household's plan, the sign-up fee has been paid: it's left out of the
    /// plan's monthly terms and charged only on the first bill.
    func testOwnPlansSignUpFeeIsAlreadyPaid() throws {
        var terms = best6
        terms.oneTimeFee = 49.99
        let feed = Feed(generatedAt: Date(), plans: [FeedPlan(
            offer: PlanOffer(id: "b", tdu: .oncor, provider: "P", product: "Bundle", price500: 0, price1000: 0, price2000: 0),
            status: .verified, terms: terms)])
        var own = plan(ends: date(2027, 1, 1))
        own.feedPlanID = "b"
        XCTAssertNil(try XCTUnwrap(own.terms(tdu: .oncor, feed: feed)).oneTimeFee)
        XCTAssertEqual(own.oneTimeFee(feed: feed), 49.99)
        let ranking = PlanRanking(feed: feed, tdu: .oncor, usage: flatYear)
        let monthly = CostEngine.monthlyBill(try XCTUnwrap(own.terms(tdu: .oncor, feed: feed)), kWh: 1000)
        let firstBill = try XCTUnwrap(BillCheck(kWh: 1000, paid: monthly + 49.99, ranking: ranking,
                                                currentTerms: own.terms(tdu: .oncor, feed: feed), oneTimeFee: 49.99))
        XCTAssertFalse(firstBill.higherThanPlan)
    }

    func testNoTimingQuestionWithoutAFeeToAvoid() {
        let noFee = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 4, 15), cancelFee: 0, energyRate: 14)
        XCTAssertNil(SwitchTiming(current: noFee, currentTerms: current14, best: bestPlan(), usage: flatYear, now: date(2027, 1, 1), calendar: calendar))
        let inWindow = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 1, 10), cancelFee: 150, energyRate: 14)
        XCTAssertNil(SwitchTiming(current: inWindow, currentTerms: current14, best: bestPlan(), usage: flatYear, now: date(2027, 1, 1), calendar: calendar))
    }

    // MARK: Renewal notice

    func testRenewalRateAgainstTheBestPlan() throws {
        var plan = CurrentPlan(providerName: "R", planName: "Old", endDate: date(2027, 2, 15), cancelFee: 150, energyRate: 14)
        XCTAssertNil(plan.renewalTerms(tdu: .oncor, feed: nil))
        plan.renewalEnergyRate = 16   // $232.733 a month
        let renewal = try XCTUnwrap(plan.renewalTerms(tdu: .oncor, feed: nil))
        XCTAssertEqual(renewal.deliveryPerKWh, 6.8673)
        let feed = Feed(generatedAt: Date(), plans: [bestPlan().plan])
        let check = try XCTUnwrap(RenewalCheck(renewalTerms: renewal, usage: flatYear,
                                               ranking: PlanRanking(feed: feed, tdu: .oncor, usage: flatYear)))
        XCTAssertEqual(check.extraCost, 12 * 100, accuracy: 0.01)    // $100 a month more than the 6¢ plan
        // An all-in renewal rate gets no delivery added.
        plan.renewalIncludesDelivery = true
        XCTAssertEqual(plan.renewalTerms(tdu: .oncor, feed: nil)?.deliveryPerKWh, 0)
    }
}

final class SwitchTimingLongContractTests: XCTestCase {
    func testFeeFreeDateMoreThanAYearOutMeansWaitingIsStayingPut() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: 2028, month: 9, day: 1))!
        let plan = CurrentPlan(providerName: "A", planName: "", endDate: end, cancelFee: 150)
        let current = PlanTerms(baseCharge: 20, energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let bestTerms = PlanTerms(baseCharge: 10, energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let usage = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
        let offer = PlanOffer(id: "b", tdu: .oncor, provider: "B", product: "B", price500: 0, price1000: 0, price2000: 0)
        let best = PricedPlan(plan: FeedPlan(offer: offer, status: .verified, terms: bestTerms), terms: bestTerms,
                              annualCost: CostEngine.annualCost(bestTerms, monthlyKWh: usage.kWh),
                              averagePrice: 0, monthlyBills: [], warnings: [])
        let t = try XCTUnwrap(SwitchTiming(current: plan, currentTerms: current, best: best, usage: usage, now: now, calendar: cal))
        XCTAssertEqual(t.waitSaving, 0, accuracy: 0.01)
        XCTAssertEqual(t.switchNowSaving, -30, accuracy: 0.01)
        XCTAssertTrue(t.waitIsBetter)
    }
}
