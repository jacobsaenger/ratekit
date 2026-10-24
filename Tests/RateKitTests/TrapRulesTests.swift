import XCTest
@testable import RateKit

final class TrapRulesTests: XCTestCase {
    func offer(_ id: String) throws -> PlanOffer {
        try XCTUnwrap(PowerToChooseCSV.offers(try Fixtures.text("ptc-2026-10-20.csv")).first { $0.id == id })
    }

    func testBillCreditCliffListsTheMonthsThatMissTheCredit() throws {
        // AP Gas & Electric SimpleSaver 12: $125 credit at 1,000 kWh or more.
        let plan = try offer("33364")
        let terms = PlanTerms(energyRate: 12.127, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
                              credits: [UsageCredit(amount: 125, minKWh: 1000)])
        let months: [Double] = [700, 650, 800, 900, 1200, 1700, 2100, 2200, 1600, 1000, 850, 750]
        let warnings = TrapRules.warnings(for: plan, terms: terms, monthlyKWh: months)
        let cliff = try XCTUnwrap(warnings.first { $0.kind == .billCreditCliff })
        XCTAssertEqual(cliff.monthsMissingCredit, [0, 1, 2, 3, 10, 11])
        XCTAssertTrue(cliff.detail.contains("6.9¢ at 1,000 kWh"))
    }

    func testPlainFixedPlanHasNoWarnings() throws {
        // Budget Power No Gimmicks 24: fixed, 24 months; its $175 fee is set to $150 to sit at the threshold.
        var plan = try offer("34402")
        plan.cancelFee = "150.00"
        XCTAssertEqual(TrapRules.warnings(for: plan, terms: nil), [])
    }

    func testOtherWarnings() throws {
        var plan = try offer("34402")
        plan.termMonths = 3
        plan.fixedRate = false
        plan.prepaid = true
        plan.cancelFee = "20 / remaining month"
        let terms = PlanTerms(energyRate: 10, deliveryPerKWh: 5, deliveryPerMonth: 3,
                              minimumUsageFees: [MinimumUsageFee(amount: 4.99, belowKWh: 400)])
        let kinds = TrapRules.warnings(for: plan, terms: terms).map(\.kind)
        XCTAssertEqual(kinds, [.minimumUsageFee, .teaserTerm, .variableRate, .prepaid, .highCancelFee])
    }

    func testCancelFeeText() {
        XCTAssertEqual(TrapRules.cancelFee("175.00"), .flat(175))
        XCTAssertEqual(TrapRules.cancelFee("20 / remaining month"), .perRemainingMonth(20))
        XCTAssertNil(TrapRules.cancelFee(""))
    }
}
