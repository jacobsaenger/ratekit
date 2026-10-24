import Foundation

/// "Am I overpaying?": one month's bill against what the best plan, and the household's
/// own plan, would charge for the same kWh.
public struct BillCheck: Equatable, Sendable {
    public var kWh: Double
    /// The bill's electricity charges before taxes, dollars.
    public var paid: Double
    public var best: PricedPlan
    /// What the best plan charges for `kWh` in one month.
    public var bestCost: Double
    /// What the household's own plan should have charged, if its terms are known.
    public var expectedCost: Double?

    /// The price paid, ¢/kWh.
    public var paidPrice: Double { paid / kWh * 100 }
    public var bestPrice: Double { bestCost / kWh * 100 }
    /// Dollars the bill cost over the best plan this month (negative when it cost less).
    public var extra: Double { paid - bestCost }

    /// True when the bill is more than 5% (and $5) above the best plan's charge for the month;
    /// smaller gaps are within what bills' own line items can move.
    public var paidMore: Bool { extra > max(5, bestCost * 0.05) }

    /// A bill this far above what the household's own plan should charge is worth a look:
    /// the contract may have ended or the rate changed.
    public static let mismatchShare = 0.10

    /// True when the bill is more than 10% (and $5) above what the household's plan should charge.
    public var higherThanPlan: Bool {
        guard let expectedCost else { return false }
        return paid - expectedCost > max(5, expectedCost * Self.mismatchShare)
    }

    /// nil for a bill that can't be checked: no kWh or amount, or no ranked plan.
    /// `oneTimeFee` is a sign-up fee the household's plan charges on this (its first) bill.
    public init?(kWh: Double, paid: Double, ranking: PlanRanking, currentTerms: PlanTerms?, oneTimeFee: Double = 0) {
        guard kWh > 0, paid > 0, let best = ranking.ranked.first else { return nil }
        self.kWh = kWh
        self.paid = paid
        self.best = best
        self.bestCost = CostEngine.monthlyBill(best.terms, kWh: kWh)
        self.expectedCost = currentTerms.map { CostEngine.monthlyBill($0, kWh: kWh) + oneTimeFee }
    }
}
