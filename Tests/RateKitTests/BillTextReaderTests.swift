import XCTest
@testable import RateKit

/// Bill text in the shapes recognized text takes: labels and values on one line or split
/// across two. Made-up bills, not copies of a provider's.
final class BillTextReaderTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }

    func testATypicalBill() {
        let text = """
        Reliant Energy
        Account Summary
        Service Period 09/12/2026 - 10/11/2026
        Meter Read Current 48211 Previous 47010
        kWh Used 1,201 kWh
        Base Charge $9.95
        Energy Charge 1,201 kWh @ $0.1345
        TDU Delivery Charges $71.40
        Total Electric Charges $242.89
        Taxes and Fees $5.12
        Total Amount Due $248.01
        Contract Expiration Date: 03/31/2027
        """
        let facts = BillTextReader.read(text, providers: ["Reliant", "TXU Energy", "Gexa Energy"], calendar: calendar)
        XCTAssertEqual(facts.kWh, 1201)
        XCTAssertEqual(facts.charges, 242.89)
        XCTAssertEqual(facts.totalDue, 248.01)
        XCTAssertEqual(facts.baseCharge, 9.95)
        XCTAssertEqual(facts.energyRate ?? 0, 13.45, accuracy: 0.0001)
        XCTAssertEqual(facts.contractEnd, calendar.date(from: DateComponents(year: 2027, month: 3, day: 31)))
        XCTAssertEqual(facts.provider, "Reliant")
    }

    /// A layout like Chariot Energy's: the rate in dollars on the energy line, the plan's end
    /// under "Expiration", and taxes listed apart from the current charges. Made-up numbers.
    func testRateInDollarsExpirationAndTaxesListedApart() throws {
        let text = """
        Your Monthly Electricity Bill
        Service Period: 09/20/26 - 10/19/26
        $401.15 due Nov 10, 2026            Mix of Current Charges
        Previous Balance $350.10
        Payments ($350.10)
        Current Charges $401.15
        Amount Due $401.15     Chariot Energy $230.40
        Tax and Regulatory $8.75
        Utility Charges $162.00
        Your Plan
        Name Chariot Choice
        Status Active
        Expiration 03/14/27
        Special Offer Date 11/20/26
        Energy
        Energy 2,400 kWh @ 0.09500 Per kWh $228.00
        ERCOT Securitization 2,400 kWh @ 0.00100 Per $2.40
        Consumption: 2,400 kWh
        TDU Delivery Charges $162.00
        Taxes
        Gross Receipts Reimbursement $8.10
        PUC Assessment $0.65
        Total Current Charges $401.15
        """
        let facts = BillTextReader.read(text, providers: ["CHARIOT ENERGY", "TXU Energy"], calendar: calendar)
        XCTAssertEqual(facts.kWh, 2400)
        XCTAssertEqual(facts.totalDue, 401.15)
        XCTAssertEqual(try XCTUnwrap(facts.charges), 401.15 - 8.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(facts.energyRate), 9.5, accuracy: 0.0001)
        XCTAssertEqual(facts.contractEnd, calendar.date(from: DateComponents(year: 2027, month: 3, day: 14)))
        XCTAssertEqual(facts.provider, "CHARIOT ENERGY")

        // A blank expiration doesn't take the offer date under it, and a percentage isn't taxes.
        let blank = BillTextReader.read("""
        Expiration
        Special Offer Date 11/20/26
        Current Charges $100.00
        Tax and Regulatory 2.18%
        """, calendar: calendar)
        XCTAssertNil(blank.contractEnd)
        XCTAssertNil(blank.charges)
    }

    func testLabelsAndValuesOnSeparateLines() {
        let text = """
        Electricity Usage
        Total kWh
        987 kWh
        Current Electricity Charges
        $131.07
        Your contract ends on
        March 3, 2027
        Energy Rate 12.9¢ per kWh
        """
        let facts = BillTextReader.read(text, calendar: calendar)
        XCTAssertEqual(facts.kWh, 987)
        XCTAssertEqual(facts.charges, 131.07)
        XCTAssertEqual(facts.energyRate ?? 0, 12.9, accuracy: 0.0001)
        XCTAssertEqual(facts.contractEnd, calendar.date(from: DateComponents(year: 2027, month: 3, day: 3)))
    }

    func testMeterReadingsAndRatesAreNotTakenAsUsage() {
        let text = """
        Current Read 52,118 Previous Read 50,902
        Energy Charge 14.2¢ per kWh
        Average price 15.1¢/kWh
        """
        XCTAssertNil(BillTextReader.read(text, calendar: calendar).kWh)
    }

    func testTaxLinesAreNotThePreTaxCharges() {
        let text = """
        Electric charges tax $4.20
        Total Electric Charges $199.00
        """
        XCTAssertEqual(BillTextReader.read(text, calendar: calendar).charges, 199.00)
    }

    func testReviewCasesThatMustNotFillAWrongNumber() {
        // A due date on the line after a contract end with no date.
        XCTAssertNil(BillTextReader.read("Contract End Date  Month-to-Month\nPayment Due Date 11/05/2026", calendar: calendar).contractEnd)
        // A start date before the end date on the same line.
        XCTAssertEqual(BillTextReader.read("Contract Start Date 04/01/2026  Contract End Date 03/31/2027", calendar: calendar).contractEnd,
                       calendar.date(from: DateComponents(year: 2027, month: 3, day: 31)))
        // A previous balance is not this bill's total.
        XCTAssertEqual(BillTextReader.read("Previous Amount Due $210.00\nTotal Amount Due $248.01", calendar: calendar).totalDue, 248.01)
        XCTAssertNil(BillTextReader.read("Previous Amount Due $210.00", calendar: calendar).totalDue)
        // A meter read under a usage heading, and an average, are not the month's usage.
        XCTAssertEqual(BillTextReader.read("Electricity Usage\nCurrent Read 4,321 kWh\nAverage monthly usage 1,450 kWh\nkWh Used 1,201 kWh", calendar: calendar).kWh, 1201)
        // A delivery energy charge is not the plan's energy rate; a monthly total is not a base charge.
        XCTAssertNil(BillTextReader.read("Delivery Energy Charge 1,201 kWh @ $0.0451", calendar: calendar).energyRate)
        XCTAssertNil(BillTextReader.read("Total monthly charges $242.89", calendar: calendar).baseCharge)
    }

    func testNothingFoundInOtherText() {
        let facts = BillTextReader.read("Hello world", calendar: calendar)
        XCTAssertTrue(facts.isEmpty)
    }
}

final class BillIdentityTests: XCTestCase {
    func testESIIDAndServiceAddress() {
        let text = """
        Service Address
        1234 Main St Apt 5
        Houston, TX 77002
        ESI ID: 1008 9010 2380 0000 0000 00
        Account Number 123456789
        """
        let facts = BillTextReader.read(text)
        XCTAssertEqual(facts.esiID, "1008901023800000000000")
        XCTAssertEqual(facts.serviceAddress, "1234 Main St Apt 5, Houston, TX 77002")
    }

    func testAddressOnTheLabelLineAnd17DigitESIID() {
        let facts = BillTextReader.read("Service Address: 88 Oak Ln, Dallas TX 75201\nESIID 10443720001234567")
        XCTAssertEqual(facts.serviceAddress, "88 Oak Ln, Dallas TX 75201")
        XCTAssertEqual(facts.esiID, "10443720001234567")
    }

    func testAccountNumbersAreNotESIIDs() {
        XCTAssertNil(BillTextReader.read("Account Number 10443720001234567").esiID)
    }
}

final class FirstBillReminderTests: XCTestCase {
    func testFirstBillCheckFiveWeeksAfterTheStart() throws {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        let start = c.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let r = try XCTUnwrap(ReminderPlanner.firstBillCheck(planName: "True Value 12", startedOn: start, now: start, calendar: c))
        XCTAssertEqual(r.date, c.date(from: DateComponents(year: 2026, month: 12, day: 6, hour: 9)))
        XCTAssertNil(ReminderPlanner.firstBillCheck(planName: "x", startedOn: start, now: r.date.addingTimeInterval(60), calendar: c))
    }
}
