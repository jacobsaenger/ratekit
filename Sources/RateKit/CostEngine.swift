import Foundation

/// Prices a plan for a household's usage. Pure arithmetic on `PlanTerms`.
public enum CostEngine {
    /// The bill in dollars for one month of `kWh` usage.
    public static func monthlyBill(_ terms: PlanTerms, kWh: Double) -> Double {
        var cents = terms.deliveryPerKWh * kWh
        let tiers = terms.energyTiers.sorted { $0.fromKWh < $1.fromKWh }
        for (index, tier) in tiers.enumerated() {
            let upper = index + 1 < tiers.count ? tiers[index + 1].fromKWh : .infinity
            let inBand = max(0, min(kWh, upper) - tier.fromKWh)
            cents += inBand * tier.rate
        }
        var dollars = cents / 100 + terms.baseCharge + terms.deliveryPerMonth + (terms.oneTimeFee ?? 0) / 12
        for credit in terms.credits where credit.applies(toKWh: kWh) {
            dollars -= credit.amount
        }
        for fee in terms.minimumUsageFees where kWh < fee.belowKWh {
            dollars += fee.amount
        }
        return dollars
    }

    /// Average price in ¢/kWh for one month, as an Electricity Facts Label states it.
    public static func averagePrice(_ terms: PlanTerms, kWh: Double) -> Double {
        guard kWh > 0 else { return 0 }
        return monthlyBill(terms, kWh: kWh) / kWh * 100
    }

    /// The total in dollars for a year of monthly usage.
    public static func annualCost(_ terms: PlanTerms, monthlyKWh: [Double]) -> Double {
        monthlyKWh.reduce(0) { $0 + monthlyBill(terms, kWh: $1) }
    }

    /// The year's average price in ¢/kWh: total cost over total usage.
    public static func annualAveragePrice(_ terms: PlanTerms, monthlyKWh: [Double]) -> Double {
        let total = monthlyKWh.reduce(0, +)
        guard total > 0 else { return 0 }
        return annualCost(terms, monthlyKWh: monthlyKWh) / total * 100
    }

    /// Dollars for the days from `start` up to (not including) `end`: each day costs its
    /// month's bill divided by the days in that month.
    public static func cost(_ terms: PlanTerms, monthlyKWh: [Double], from start: Date, to end: Date,
                            calendar: Calendar = .current) -> Double {
        guard monthlyKWh.count == 12 else { return 0 }
        var total = 0.0
        var day = calendar.startOfDay(for: start)
        let stop = calendar.startOfDay(for: end)
        var bills: [Int: Double] = [:]
        while day < stop {
            let month = calendar.component(.month, from: day) - 1
            let days = Double(calendar.range(of: .day, in: .month, for: day)?.count ?? 30)
            let bill = bills[month] ?? monthlyBill(terms, kWh: monthlyKWh[month])
            bills[month] = bill
            total += bill / days
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }
}
