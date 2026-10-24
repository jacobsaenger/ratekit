import XCTest
@testable import RateKit

final class SignUpTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }

    func testCancelDeadlineSkipsWeekendsAndHolidays() {
        // Thursday Oct 22, 2026 → Fri 23, Mon 26, Tue 27.
        XCTAssertEqual(ReminderPlanner.cancelDeadline(termsReceived: day(2026, 10, 22), calendar: calendar), day(2026, 10, 27))
        // Tuesday Nov 24, 2026 → Wed 25, (Thanksgiving Thu 26), Fri 27, Mon 30.
        XCTAssertEqual(ReminderPlanner.cancelDeadline(termsReceived: day(2026, 11, 24), calendar: calendar), day(2026, 11, 30))
        // July 4, 2026 is a Saturday, observed Friday July 3: Thu July 2 → Mon 6, Tue 7, Wed 8.
        XCTAssertEqual(ReminderPlanner.cancelDeadline(termsReceived: day(2026, 7, 2), calendar: calendar), day(2026, 7, 8))
    }

    func testHolidayRules() {
        XCTAssertFalse(FederalBusinessDays.isBusinessDay(day(2027, 1, 18), calendar: calendar))   // MLK Day
        XCTAssertFalse(FederalBusinessDays.isBusinessDay(day(2027, 5, 31), calendar: calendar))   // Memorial Day
        XCTAssertFalse(FederalBusinessDays.isBusinessDay(day(2027, 12, 24), calendar: calendar))  // Christmas on Saturday, observed Friday
        XCTAssertTrue(FederalBusinessDays.isBusinessDay(day(2027, 12, 27), calendar: calendar))
    }

    func testWelcomeLetterMatchesThePlan() {
        let letter = """
        Welcome to True Power! Your plan: True Value 12
        Contract Term 12 Months
        Average price per kWh 500 kWh 12.3¢ 1,000 kWh 11.8¢ 2,000 kWh 11.6¢
        """
        let c = SignUpConfirmation(text: letter, product: "True Value 12", price1000: 11.8, termMonths: 12)
        XCTAssertTrue(c.allMatch)
    }

    func testNearMissesAreNotMatches() {
        // A longer plan name, a stray month count, and a non-1,000 kWh price.
        let a = SignUpConfirmation(text: "Your plan: Digital Choice 36. Contract term 36 months.", product: "Digital Choice 3", price1000: 9.9, termMonths: 3)
        XCTAssertEqual(a.planName, .notFound)
        XCTAssertEqual(a.term, .differs("36"))
        let b = SignUpConfirmation(text: "True Value 12 Plus. Term 24 months, based on your usage over the last 12 months. Energy Charge 11.8 cents.",
                                   product: "True Value 12", price1000: 11.8, termMonths: 12, otherPlans: ["True Value 12 Plus", "True Value 20"])
        XCTAssertEqual(b.planName, .differs("True Value 12 Plus"))
        XCTAssertEqual(b.term, .differs("24"))
        XCTAssertEqual(b.price, .notFound)
        XCTAssertFalse(b.allMatch)
    }

    func testAFactsLabelTableGivesThe1000kWhPrice() {
        let efl = "Average Monthly Use 500 kWh 1,000 kWh 2,000 kWh\nAverage Price per kWh 12.3¢ 11.8¢ 11.6¢\nTrue Value 12\nContract Term 12 Months"
        XCTAssertTrue(SignUpConfirmation(text: efl, product: "True Value 12", price1000: 11.8, termMonths: 12).allMatch)
    }

    func testNewYearsDayOnASaturdayIsObservedTheFridayBefore() {
        // Jan 1, 2028 is a Saturday: Dec 31, 2027 is the holiday. Wed Dec 29 → Thu 30, Mon Jan 3, Tue Jan 4.
        XCTAssertEqual(ReminderPlanner.cancelDeadline(termsReceived: day(2027, 12, 29), calendar: calendar), day(2028, 1, 4))
    }

    func testADifferentPlanIsFlagged() {
        let letter = "Welcome! Your plan: Simple Saver 24. Term: 24 months. Price at 1,000 kWh 14.2¢."
        let c = SignUpConfirmation(text: letter, product: "True Value 12", price1000: 11.8, termMonths: 12)
        XCTAssertEqual(c.planName, .notFound)
        XCTAssertEqual(c.price, .differs("14.2¢"))
        XCTAssertEqual(c.term, .differs("24"))
        XCTAssertTrue(c.anyDiffers)
    }
}
