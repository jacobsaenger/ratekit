import Foundation

extension YearOfUsage {
    /// Every month's usage scaled by `factor` (rounded to whole kWh, as meters bill).
    public func scaled(by factor: Double) -> YearOfUsage {
        YearOfUsage(kWh: kWh.map { ($0 * factor).rounded() }, estimated: estimated)
    }
}

/// The plan that stays closest to the cheapest if the household's usage changes: the one
/// whose largest yearly gap to the cheapest plan, across the usage scenarios, is smallest.
public struct SafePick: Equatable, Sendable {
    /// Usage 20% lower, as it is, and 30% higher.
    public static let scenarios: [Double] = [0.8, 1.0, 1.3]

    public var planID: String
    /// The most it costs above the cheapest plan in any scenario, dollars a year.
    public var worstExtra: Double

    public init?(feed: Feed, tdu: TDU, usage: YearOfUsage, filters: PlanFilters = PlanFilters(), profile: UsageProfile? = nil,
                 hasSolar: Bool = false) {
        var costs: [String: [Double]] = [:]
        var cheapest: [Double] = []
        for factor in Self.scenarios {
            let ranked = PlanRanking(feed: feed, tdu: tdu, usage: usage.scaled(by: factor), filters: filters, profile: profile, hasSolar: hasSolar).ranked
            guard let first = ranked.first else { return nil }
            cheapest.append(first.annualCost)
            for plan in ranked { costs[plan.id, default: []].append(plan.annualCost) }
        }
        let worst = costs.compactMap { id, values -> (String, Double)? in
            guard values.count == cheapest.count else { return nil }
            return (id, zip(values, cheapest).map { $0 - $1 }.max() ?? 0)
        }
        guard let pick = worst.min(by: { ($0.1, $0.0) < ($1.1, $1.0) }) else { return nil }
        self.planID = pick.0
        self.worstExtra = pick.1
    }
}
