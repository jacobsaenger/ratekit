import Foundation

/// A change in a TDU's delivery charges, which every plan in the area passes through: what it
/// adds to (or takes off) one household's year. Switching plans doesn't avoid it.
public struct DeliveryChange: Codable, Equatable, Sendable {
    public var tdu: TDU
    public var old: TDUCharges
    public var new: TDUCharges

    /// nil when the charges are the same.
    public init?(tdu: TDU, old: TDUCharges, new: TDUCharges) {
        guard abs(old.perKWh - new.perKWh) > 1e-9 || abs(old.perMonth - new.perMonth) > 1e-9 else { return nil }
        self.tdu = tdu
        self.old = old
        self.new = new
    }

    /// Dollars a year at this usage; negative when the charges fell.
    public func yearly(for usage: YearOfUsage) -> Double {
        usage.total * (new.perKWh - old.perKWh) / 100 + 12 * (new.perMonth - old.perMonth)
    }
}

/// The coming months' bills on a plan, and how much of each is the TDU's delivery charges.
public enum BillForecast {
    public struct Month: Equatable, Sendable {
        public var year: Int
        /// 1 = January.
        public var month: Int
        public var total: Double
        public var delivery: Double
    }

    /// `count` months starting with the one `from` falls in, at the household's usage for each
    /// month. Taxes aren't included.
    public static func months(_ count: Int, terms: PlanTerms, usage: YearOfUsage, from: Date,
                              calendar: Calendar = .current) -> [Month] {
        let c = calendar.dateComponents([.year, .month], from: from)
        guard let year = c.year, let month = c.month else { return [] }
        return (0..<count).map { i in
            let index = year * 12 + (month - 1) + i
            let m = index % 12, kWh = usage.kWh[m]
            return Month(year: index / 12, month: m + 1, total: CostEngine.monthlyBill(terms, kWh: kWh),
                         delivery: terms.deliveryPerKWh * kWh / 100 + terms.deliveryPerMonth)
        }
    }
}
