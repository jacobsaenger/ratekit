import XCTest
@testable import RateKit

final class BillCheckTests: XCTestCase {
    func ranking(_ terms: PlanTerms) -> PlanRanking {
        let offer = PlanOffer(id: "best", tdu: .oncor, provider: "B", product: "Best 12", price500: 0, price1000: 0, price2000: 0)
        let feed = Feed(generatedAt: Date(), plans: [FeedPlan(offer: offer, status: .verified, terms: terms)])
        return PlanRanking(feed: feed, tdu: .oncor, usage: UsageEstimate.estimate(for: .house1500to1999))
    }

    func testBillAgainstTheBestPlanAndTheHouseholdsOwnPlan() throws {
        // Best plan: 10¢ all in. Own plan: 12¢ all in. 1,000 kWh billed at $180.
        let best = PlanTerms(energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let own = PlanTerms(energyRate: 12, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let check = try XCTUnwrap(BillCheck(kWh: 1000, paid: 180, ranking: ranking(best), currentTerms: own))
        XCTAssertEqual(check.bestCost, 100, accuracy: 0.001)
        XCTAssertEqual(check.extra, 80, accuracy: 0.001)
        XCTAssertEqual(check.paidPrice, 18, accuracy: 0.001)
        XCTAssertEqual(check.expectedCost ?? 0, 120, accuracy: 0.001)
        XCTAssertTrue(check.higherThanPlan)
    }

    func testABillCloseToTheOwnPlanIsNotFlagged() throws {
        let best = PlanTerms(energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let own = PlanTerms(energyRate: 12, deliveryPerKWh: 0, deliveryPerMonth: 0)
        let check = try XCTUnwrap(BillCheck(kWh: 1000, paid: 125, ranking: ranking(best), currentTerms: own))
        XCTAssertFalse(check.higherThanPlan)
        XCTAssertFalse(try XCTUnwrap(BillCheck(kWh: 1000, paid: 125, ranking: ranking(best), currentTerms: nil)).higherThanPlan)
    }

    func testEmptyBillsAreNotChecked() {
        let best = PlanTerms(energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)
        XCTAssertNil(BillCheck(kWh: 0, paid: 100, ranking: ranking(best), currentTerms: nil))
        XCTAssertNil(BillCheck(kWh: 1000, paid: 0, ranking: ranking(best), currentTerms: nil))
    }
}

final class PriceHistoryTests: XCTestCase {
    func testMergeReplacesTheSameDayAndDropsOldPoints() {
        let now = PriceTrend.date("2026-10-22")!.addingTimeInterval(12 * 3600)
        let old: [String: [PricePoint]] = ["oncor": [PricePoint(date: "2025-01-01", cents: 9),
                                                    PricePoint(date: "2026-10-21", cents: 12),
                                                    PricePoint(date: "2026-10-22", cents: 13)]]
        let merged = PriceHistory.merged(old, adding: ["oncor": PricePoint(date: "2026-10-22", cents: 11.5),
                                                       "tnmp": PricePoint(date: "2026-10-22", cents: 14)], now: now)
        XCTAssertEqual(merged["oncor"], [PricePoint(date: "2026-10-21", cents: 12), PricePoint(date: "2026-10-22", cents: 11.5)])
        XCTAssertEqual(merged["tnmp"], [PricePoint(date: "2026-10-22", cents: 14)])
    }

    func testTodaysPointIsTheCheapestPlanForTheReferenceHome() {
        let cheap = PlanOffer(id: "a", tdu: .oncor, provider: "A", product: "A", price500: 0, price1000: 0, price2000: 0)
        let dear = PlanOffer(id: "b", tdu: .oncor, provider: "B", product: "B", price500: 0, price1000: 0, price2000: 0)
        let feed = Feed(generatedAt: Date(), plans: [
            FeedPlan(offer: cheap, status: .verified, terms: PlanTerms(energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0)),
            FeedPlan(offer: dear, status: .verified, terms: PlanTerms(energyRate: 14, deliveryPerKWh: 0, deliveryPerMonth: 0))])
        let points = PriceHistory.points(for: feed, on: PriceTrend.date("2026-10-22")!.addingTimeInterval(3600))
        XCTAssertEqual(points["oncor"]?.date, "2026-10-22")
        // Both plans include delivery in their rates, so the cheaper one's price is its 10¢.
        XCTAssertEqual(points["oncor"]?.cents ?? 0, 10, accuracy: 0.001)
        XCTAssertNil(points["tnmp"])
    }

    func testTrendNeedsTwoDaysAndFindsTheMonthAgoPoint() throws {
        XCTAssertNil(PriceTrend(points: [PricePoint(date: "2026-10-22", cents: 12)]))
        let short = try XCTUnwrap(PriceTrend(points: [PricePoint(date: "2026-10-21", cents: 12), PricePoint(date: "2026-10-22", cents: 11)]))
        XCTAssertNil(short.monthAgo)
        XCTAssertEqual(short.low.cents, 11)
        let long = try XCTUnwrap(PriceTrend(points: [PricePoint(date: "2026-09-20", cents: 13), PricePoint(date: "2026-09-23", cents: 12.5),
                                                     PricePoint(date: "2026-10-10", cents: 12), PricePoint(date: "2026-10-22", cents: 11.7)]))
        XCTAssertEqual(long.monthAgo?.date, "2026-09-23")
        XCTAssertEqual(long.monthChange ?? 0, -6.4, accuracy: 0.01)
        XCTAssertEqual(long.high.cents, 13)
    }
}

final class AfterEndReminderTests: XCTestCase {
    func testRemindersOneAndSevenDaysAfterTheEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let plan = CurrentPlan(providerName: "R", planName: "Secure 12", endDate: end, cancelFee: 150)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22))!
        let reminders = ReminderPlanner.afterEnd(for: plan, now: now, calendar: calendar)
        XCTAssertEqual(reminders.map(\.daysBefore), [-1, -7])
        XCTAssertEqual(reminders[0].date, calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        XCTAssertTrue(reminders[0].body.contains("month-to-month"))
        let later = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        XCTAssertEqual(ReminderPlanner.afterEnd(for: plan, now: later, calendar: calendar).map(\.daysBefore), [-7])
    }
}
