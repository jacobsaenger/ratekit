import XCTest
@testable import RateKit

/// Expected values are worked by hand from each plan's Facts label (2026-10-20) and
/// match the averages the label itself prints.
final class CostEngineTests: XCTestCase {
    /// AP Gas & Electric SimpleSaver 12, Oncor: 12.127¢ energy, 6.8673¢ + $4.06 delivery,
    /// $125 credit at 1,000 kWh or more.
    let simpleSaver = PlanTerms(
        energyRate: 12.127, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
        credits: [UsageCredit(amount: 125, minKWh: 1000)]
    )

    func testBillCreditInsideAndOutsideItsRange() {
        // 500 kWh: 500 × 18.9943¢ = $94.97 + $4.06 = $99.03, no credit.
        XCTAssertEqual(CostEngine.monthlyBill(simpleSaver, kWh: 500), 99.0315, accuracy: 0.0001)
        // 999 kWh misses the credit by one kWh.
        XCTAssertEqual(CostEngine.monthlyBill(simpleSaver, kWh: 999), 193.8131, accuracy: 0.0001)
        // 1,000 kWh: $189.94 + $4.06 − $125 = $69.00.
        XCTAssertEqual(CostEngine.monthlyBill(simpleSaver, kWh: 1000), 69.003, accuracy: 0.0001)
        XCTAssertEqual(CostEngine.averagePrice(simpleSaver, kWh: 500), 19.8063, accuracy: 0.0001)
        XCTAssertEqual(CostEngine.averagePrice(simpleSaver, kWh: 1000), 6.9003, accuracy: 0.0001)
        XCTAssertEqual(CostEngine.averagePrice(simpleSaver, kWh: 2000), 12.9473, accuracy: 0.0001)
    }

    func testStackedCreditsAndBaseCharge() {
        // Constellation 12 month with usage credit, Oncor: $35 at ≥1,000 kWh plus $15 more at ≥2,000.
        let terms = PlanTerms(
            energyRate: 12.22, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06,
            credits: [UsageCredit(amount: 35, minKWh: 1000), UsageCredit(amount: 15, minKWh: 2000)]
        )
        // 2,000 kWh: 2000 × 19.0873¢ = $381.75 + $4.06 − $50 = $335.81 → 16.8¢.
        XCTAssertEqual(CostEngine.monthlyBill(terms, kWh: 2000), 335.806, accuracy: 0.0001)
        XCTAssertEqual(CostEngine.averagePrice(terms, kWh: 2000), 16.79, accuracy: 0.01)
    }

    func testMinimumUsageFeeAppliesOnlyBelowItsThreshold() {
        // Just Energy Smart Choice 12, AEP North: $4.99 fee under 400 kWh.
        let terms = PlanTerms(
            energyRate: 17.9, deliveryPerKWh: 5.5751, deliveryPerMonth: 3.24,
            credits: [UsageCredit(amount: 125, minKWh: 1000)],
            minimumUsageFees: [MinimumUsageFee(amount: 4.99, belowKWh: 400)]
        )
        // 399 kWh: 399 × 23.4751¢ = $93.67 + $3.24 + $4.99 = $101.90.
        XCTAssertEqual(CostEngine.monthlyBill(terms, kWh: 399), 101.8956, accuracy: 0.0001)
        // 400 kWh: no fee.
        XCTAssertEqual(CostEngine.monthlyBill(terms, kWh: 400), 97.1404, accuracy: 0.0001)
        XCTAssertEqual(CostEngine.averagePrice(terms, kWh: 500), 24.12, accuracy: 0.01)
    }

    func testEnergyChargedOnlyAboveATier() {
        // Texans Choice Texas Instant 12: $125 base; 14¢ only on usage above 1,000 kWh.
        let terms = PlanTerms(
            baseCharge: 125,
            energyTiers: [EnergyTier(fromKWh: 0, rate: 0), EnergyTier(fromKWh: 1000, rate: 14)],
            deliveryPerKWh: 0, deliveryPerMonth: 0
        )
        XCTAssertEqual(CostEngine.averagePrice(terms, kWh: 500), 25.0, accuracy: 0.0001)
        XCTAssertEqual(CostEngine.averagePrice(terms, kWh: 1000), 12.5, accuracy: 0.0001)
        // 2,000 kWh: $125 + 1,000 × 14¢ = $265 → 13.25¢.
        XCTAssertEqual(CostEngine.averagePrice(terms, kWh: 2000), 13.25, accuracy: 0.0001)
    }

    func testAnnualCostSumsMonths() {
        let months: [Double] = [900, 800, 850, 950, 1200, 1600, 2000, 2100, 1700, 1100, 900, 950]
        let expected = months.map { CostEngine.monthlyBill(simpleSaver, kWh: $0) }.reduce(0, +)
        XCTAssertEqual(CostEngine.annualCost(simpleSaver, monthlyKWh: months), expected, accuracy: 0.0001)
        XCTAssertEqual(
            CostEngine.annualAveragePrice(simpleSaver, monthlyKWh: months),
            expected / months.reduce(0, +) * 100, accuracy: 0.0001
        )
    }
}
