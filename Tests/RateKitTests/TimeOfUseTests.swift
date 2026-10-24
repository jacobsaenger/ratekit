import XCTest
@testable import RateKit

/// Time-of-use labels from four providers (Power to Choose, 2026-10-22). The price check
/// only sees the label's assumed shares, so these pin each window's hours, days and months.
final class TimeOfUseReaderTests: XCTestCase {
    func offer(_ id: String, _ tdu: TDU, _ p500: Double, _ p1000: Double, _ p2000: Double) -> PlanOffer {
        PlanOffer(id: id, tdu: tdu, provider: id, product: id, price500: p500, price1000: p1000, price2000: p2000, timeOfUse: true)
    }

    func testTXUFreeNightsAllYearWithASummerBonus() throws {
        let t = try XCTUnwrap(TimeOfUseReader.read(offer("36601", .oncor, 20.9, 19.5, 18.8), labelText: try Fixtures.text("efl/tou-txu-free-nights.txt")))
        XCTAssertEqual(t.energyRate, 20.2)
        XCTAssertEqual(t.baseCharge, 9.95)
        XCTAssertEqual(t.windows.count, 2)
        let nights = t.windows[0], summer = t.windows[1]
        XCTAssertEqual([nights.startMinute, nights.endMinute], [21 * 60, 5 * 60])   // 9:00 p.m. through 4:59 a.m.
        XCTAssertNil(nights.months)
        XCTAssertEqual(nights.credit, 20.2, accuracy: 1e-9)                          // 100% of the energy charge
        XCTAssertEqual([summer.startMinute, summer.endMinute], [21 * 60, 5 * 60])
        XCTAssertEqual(summer.months, [7, 8, 9])
        XCTAssertEqual(summer.credit, 5.05, accuracy: 1e-9)                          // an additional 25%
    }

    func testChariotBrightNights() throws {
        let t = try XCTUnwrap(TimeOfUseReader.read(offer("34725", .centerPoint, 13.8, 12.3, 11.6), labelText: try Fixtures.text("efl/tou-chariot-bright-nights.txt")))
        XCTAssertEqual(t.windows.count, 1)
        XCTAssertEqual([t.windows[0].startMinute, t.windows[0].endMinute], [23 * 60, 6 * 60])
        XCTAssertNil(t.windows[0].months)
        XCTAssertEqual(t.windows[0].days, .all)
        XCTAssertEqual(t.windows[0].credit, t.energyRate, accuracy: 1e-9)          // nights at 0¢
    }

    func testChampionFreeWeekends() throws {
        let t = try XCTUnwrap(TimeOfUseReader.read(offer("18540", .aepCentral, 13.3, 13.0, 12.9), labelText: try Fixtures.text("efl/tou-champion-free-weekends.txt")))
        XCTAssertEqual(t.windows.count, 1)
        XCTAssertEqual(t.windows[0].days, .weekends)
        XCTAssertTrue(t.windows[0].contains(minute: 600, weekend: true, month: 3))
        XCTAssertFalse(t.windows[0].contains(minute: 600, weekend: false, month: 3))
    }

    func testAmigoSolarDaysWithItsOneTimeFee() throws {
        let t = try XCTUnwrap(TimeOfUseReader.read(offer("21776", .aepCentral, 10.4, 9.6, 9.3), labelText: try Fixtures.text("efl/tou-amigo-simply-days.txt")))
        XCTAssertEqual([t.windows[0].startMinute, t.windows[0].endMinute], [9 * 60, 16 * 60])
        XCTAssertEqual(t.oneTimeFee, 49.99)
    }

    func testAReadingThatMissesThePublishedPricesIsRefused() throws {
        XCTAssertNil(TimeOfUseReader.read(offer("36601", .oncor, 20.9, 18.0, 18.8), labelText: try Fixtures.text("efl/tou-txu-free-nights.txt")))
    }
}

final class UsageProfileTests: XCTestCase {
    /// A month with all usage at night (11 p.m.–6 a.m.) on weekdays.
    func nightProfile() -> UsageProfile {
        var month = Array(repeating: 0.0, count: 192)
        for slot in 0..<96 where slot >= 92 || slot < 24 { month[slot] = 1 }
        return UsageProfile(slots: Array(repeating: month, count: 12))
    }

    func testWindowShareAndMonthlyBill() {
        let nights = TimeOfUseTerms.Window(name: "Nights", startMinute: 23 * 60, endMinute: 6 * 60, credit: 10, labelShare: 0.35)
        let weekends = TimeOfUseTerms.Window(name: "Weekends", startMinute: 0, endMinute: 1440, days: .weekends, credit: 10, labelShare: 0.3)
        let profile = nightProfile()
        XCTAssertEqual(profile.share(of: nights, month: 1), 1)
        XCTAssertEqual(profile.share(of: weekends, month: 1), 0)
        let terms = TimeOfUseTerms(baseCharge: 10, energyRate: 10, windows: [nights], deliveryPerKWh: 5, deliveryPerMonth: 4)
        // 1,000 kWh all at night: energy fully credited, delivery still due.
        XCTAssertEqual(terms.monthlyBill(kWh: 1000, month: 1) { profile.share(of: $0, month: 1) ?? 0 }, 10 + 4 + 50, accuracy: 1e-9)
    }

    func testSummerOnlyWindowsCountOnlyInTheirMonths() {
        let bonus = TimeOfUseTerms.Window(name: "Bonus", startMinute: 0, endMinute: 1440, months: [7], credit: 5, labelShare: 0.1)
        let terms = TimeOfUseTerms(baseCharge: 0, energyRate: 10, windows: [bonus], deliveryPerKWh: 0, deliveryPerMonth: 0)
        XCTAssertEqual(terms.monthlyBill(kWh: 100, month: 7) { _ in 1 }, 5, accuracy: 1e-9)
        XCTAssertEqual(terms.monthlyBill(kWh: 100, month: 8) { _ in 1 }, 10, accuracy: 1e-9)
    }
}

final class TimeOfUseRankingTests: XCTestCase {
    func testANightOwlSeesFreeNightsRankedAndADayPersonDoesNot() throws {
        let nights = TimeOfUseTerms.Window(name: "Nights", startMinute: 21 * 60, endMinute: 5 * 60, credit: 20, labelShare: 0.4)
        let tou = TimeOfUseTerms(baseCharge: 10, energyRate: 20, windows: [nights], deliveryPerKWh: 0, deliveryPerMonth: 0)
        let touOffer = PlanOffer(id: "tou", tdu: .oncor, provider: "T", product: "Free Nights", price500: 0, price1000: 0, price2000: 0, timeOfUse: true)
        var touPlan = FeedPlan(offer: touOffer, status: .timeOfUse, terms: nil)
        touPlan.timeOfUse = tou
        let flatOffer = PlanOffer(id: "flat", tdu: .oncor, provider: "F", product: "Flat", price500: 0, price1000: 0, price2000: 0)
        let flat = FeedPlan(offer: flatOffer, status: .verified, terms: PlanTerms(energyRate: 14, deliveryPerKWh: 0, deliveryPerMonth: 0))
        let feed = Feed(generatedAt: Date(), plans: [touPlan, flat])
        let usage = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))

        func profile(nightShare: Double) -> UsageProfile {
            var month = Array(repeating: 0.0, count: 192)
            for slot in 0..<192 { month[slot] = ((slot % 96) >= 84 || (slot % 96) < 20) ? nightShare / 64 : (1 - nightShare) / 128 }
            return UsageProfile(slots: Array(repeating: month, count: 12))
        }
        // No time-of-day data: listed, not ranked.
        XCTAssertEqual(PlanRanking(feed: feed, tdu: .oncor, usage: usage).timeOfUse.map(\.id), ["tou"])
        // 60% at night: 1,000 kWh × 20¢ × 40% daytime = $80 + $10 base, below the flat $140.
        let owl = PlanRanking(feed: feed, tdu: .oncor, usage: usage, profile: profile(nightShare: 0.6))
        XCTAssertEqual(owl.ranked.map(\.id), ["tou", "flat"])
        XCTAssertEqual(owl.ranked[0].annualCost, 12 * 90, accuracy: 0.01)
        XCTAssertEqual(owl.ranked[0].windowShares[0], 0.6, accuracy: 1e-9)
        // 10% at night: $180 + $10 a month, above the flat plan.
        let day = PlanRanking(feed: feed, tdu: .oncor, usage: usage, profile: profile(nightShare: 0.1))
        XCTAssertEqual(day.ranked.map(\.id), ["flat", "tou"])
    }
}

final class ProfileImportTests: XCTestCase {
    func testFifteenMinuteFilesGiveATimeOfDayProfile() throws {
        var lines = ["ESIID,USAGE_DATE,REVISION_DATE,USAGE_START_TIME,USAGE_END_TIME,USAGE_KWH,ESTIMATED_ACTUAL,CONSUMPTION_SURPLUSGENERATION"]
        for day in 1...30 {
            for q in 0..<96 {
                let t = String(format: "%02d:%02d", q / 4, q % 4 * 15)
                // 1 kWh in each night slot (11 p.m.–6 a.m.), nothing otherwise.
                let kWh = (q >= 92 || q < 24) ? 1.0 : 0.0
                lines.append("'1,\(String(format: "04/%02d/2026", day)),x,\(t),\(t),\(kWh),A,Consumption")
            }
        }
        let result = try SmartMeterImport.read(lines.joined(separator: "\n"))
        let profile = try XCTUnwrap(result.profile)
        let nights = TimeOfUseTerms.Window(name: "N", startMinute: 23 * 60, endMinute: 6 * 60, credit: 1, labelShare: 0)
        XCTAssertEqual(profile.share(of: nights, month: 4), 1)
        XCTAssertNil(profile.share(of: nights, month: 5))
    }

    func testDailyFilesHaveNoProfile() throws {
        var lines = ["ESIID,READ_DATE,REVISION_DATE,START_READING,END_READING"]
        for day in 1...30 { lines.append("1,\(String(format: "04/%02d/2026", day)),x,0,40") }
        XCTAssertNil(try SmartMeterImport.read(lines.joined(separator: "\n")).profile)
    }
}

final class TimeOfUseReviewTests: XCTestCase {
    let nights = TimeOfUseTerms.Window(name: "Free Nights", startMinute: 21 * 60, endMinute: 5 * 60, credit: 20, labelShare: 0.4)
    let bonus = TimeOfUseTerms.Window(name: "Cool Summer", startMinute: 21 * 60, endMinute: 5 * 60, months: [7, 8, 9], credit: 5, labelShare: 0.12)

    func testTheSummerBonusNeverExceedsTheDaytimeEnergyCharges() {
        let terms = TimeOfUseTerms(baseCharge: 0, energyRate: 20, windows: [nights, bonus], deliveryPerKWh: 0, deliveryPerMonth: 0)
        // 90% at night in July: the bonus would be 5¢ × 900 = $45, capped at 20¢ × 100 daytime kWh = $20.
        // Energy $200 − nights $180 − bonus $20 = $0.
        XCTAssertEqual(terms.monthlyBill(kWh: 1000, month: 7) { _ in 0.9 }, 0, accuracy: 1e-9)
        // 50% at night: the bonus ($25) is under the cap ($100).
        XCTAssertEqual(terms.monthlyBill(kWh: 1000, month: 7) { _ in 0.5 }, 200 - 100 - 25, accuracy: 1e-9)
    }

    func testPartOfAYearOfTimeOfDayDataDoesNotPriceThePlan() {
        var slots = Array(repeating: Array(repeating: 1.0, count: 192), count: 12)
        slots[6] = Array(repeating: 0, count: 192)   // no July data
        let tou = TimeOfUseTerms(baseCharge: 0, energyRate: 20, windows: [nights], deliveryPerKWh: 0, deliveryPerMonth: 0)
        let offer = PlanOffer(id: "t", tdu: .oncor, provider: "T", product: "T", price500: 0, price1000: 0, price2000: 0, timeOfUse: true)
        let usage = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
        XCTAssertNil(PlanRanking.price(FeedPlan(offer: offer, status: .timeOfUse, terms: nil), tou, usage: usage, profile: UsageProfile(slots: slots)))
    }

    func testHomesWithSolarDontSeePlansThatExcludeThem() {
        var tou = TimeOfUseTerms(baseCharge: 0, energyRate: 20, windows: [nights], deliveryPerKWh: 0, deliveryPerMonth: 0)
        tou.eligibility = "Customers with electric vehicles, batteries, and/or solar panels are ineligible."
        let offer = PlanOffer(id: "t", tdu: .oncor, provider: "T", product: "T", price500: 0, price1000: 0, price2000: 0, timeOfUse: true)
        var plan = FeedPlan(offer: offer, status: .timeOfUse, terms: nil)
        plan.timeOfUse = tou
        let feed = Feed(generatedAt: Date(), plans: [plan])
        let usage = YearOfUsage(kWh: Array(repeating: 1000, count: 12), estimated: Array(repeating: false, count: 12))
        let profile = UsageProfile(slots: Array(repeating: Array(repeating: 1.0, count: 192), count: 12))
        XCTAssertEqual(PlanRanking(feed: feed, tdu: .oncor, usage: usage, profile: profile).ranked.count, 1)
        XCTAssertEqual(PlanRanking(feed: feed, tdu: .oncor, usage: usage, profile: profile, hasSolar: true).ranked.count, 0)
    }

    func testTXUsEligibilityLineIsRead() throws {
        let offer = PlanOffer(id: "36601", tdu: .oncor, provider: "T", product: "T", price500: 20.9, price1000: 19.5, price2000: 18.8, timeOfUse: true)
        let t = try XCTUnwrap(TimeOfUseReader.read(offer, labelText: try Fixtures.text("efl/tou-txu-free-nights.txt")))
        XCTAssertTrue(t.excludesSolar)
    }
}
