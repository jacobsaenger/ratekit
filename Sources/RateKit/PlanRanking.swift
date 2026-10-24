import Foundation

/// Which plans to show.
public struct PlanFilters: Equatable, Codable, Sendable {
    public enum Term: String, CaseIterable, Codable, Sendable {
        case any, atLeast12, upTo6, from7to12, from13to24, over24

        public func contains(_ months: Int) -> Bool {
            switch self {
            case .any: true
            case .atLeast12: months >= 12
            case .upTo6: months <= 6
            case .from7to12: (7...12).contains(months)
            case .from13to24: (13...24).contains(months)
            case .over24: months > 24
            }
        }
    }

    /// Twelve months or longer by default: a shorter plan's yearly cost assumes its rate
    /// lasts the year, but it rolls onto an unknown renewal rate when it ends.
    public var term: Term = .atLeast12
    public var fixedRateOnly = false
    public var minimumRenewablePercent = 0
    public var hidePrepaid = false
    public var hideMinimumUsageFees = false
    /// Only plans whose label says the provider buys back excess solar generation.
    public var solarBuybackOnly = false
    /// Hide providers in the PUCT complaint scorecard's two lowest groups (1–2 of 5).
    /// Providers without a rating stay listed.
    public var hideHighComplaintProviders = false
    /// Hide plans whose price depends on autopay or paperless billing.
    public var hidePaymentRequirements = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case term, fixedRateOnly, minimumRenewablePercent, hidePrepaid, hideMinimumUsageFees
        case solarBuybackOnly, hideHighComplaintProviders, hidePaymentRequirements
    }

    /// Filters saved by an earlier version lack the newer keys; they keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decodeIfPresent(Term.self, forKey: .term) ?? .atLeast12
        fixedRateOnly = try c.decodeIfPresent(Bool.self, forKey: .fixedRateOnly) ?? false
        minimumRenewablePercent = try c.decodeIfPresent(Int.self, forKey: .minimumRenewablePercent) ?? 0
        hidePrepaid = try c.decodeIfPresent(Bool.self, forKey: .hidePrepaid) ?? false
        hideMinimumUsageFees = try c.decodeIfPresent(Bool.self, forKey: .hideMinimumUsageFees) ?? false
        solarBuybackOnly = try c.decodeIfPresent(Bool.self, forKey: .solarBuybackOnly) ?? false
        hideHighComplaintProviders = try c.decodeIfPresent(Bool.self, forKey: .hideHighComplaintProviders) ?? false
        hidePaymentRequirements = try c.decodeIfPresent(Bool.self, forKey: .hidePaymentRequirements) ?? false
    }

    public func allows(_ plan: FeedPlan) -> Bool {
        let o = plan.offer
        if !term.contains(o.termMonths) { return false }
        if fixedRateOnly && !o.fixedRate { return false }
        if o.renewablePercent < minimumRenewablePercent { return false }
        if hidePrepaid && o.prepaid { return false }
        if hideMinimumUsageFees && !(plan.terms?.minimumUsageFees.isEmpty ?? !o.minimumUsageFeesOrCredits) { return false }
        if solarBuybackOnly && plan.buysBackSolar != true { return false }
        if hideHighComplaintProviders, let score = o.complaintScore, score <= 2 { return false }
        if hidePaymentRequirements && plan.payment != nil { return false }
        return true
    }
}

/// A verified plan priced for one household.
public struct PricedPlan: Identifiable, Equatable, Sendable {
    public var plan: FeedPlan
    public var terms: PlanTerms
    /// Dollars for the household's 12 months.
    public var annualCost: Double
    /// ¢/kWh over the year.
    public var averagePrice: Double
    /// Dollars per month, January first.
    public var monthlyBills: [Double]
    public var warnings: [TrapWarning]
    /// Set for a time-of-use plan priced with the household's time-of-day usage: its
    /// windows, and the share of the year's usage that fell in each. `terms` then carries
    /// the year's effective energy rate.
    public var timeOfUse: TimeOfUseTerms? = nil
    public var windowShares: [Double] = []

    public var id: String { plan.id }
}

/// The plans available in one service area, priced for a household's year of usage.
public struct PlanRanking: Equatable, Sendable {
    /// Verified plans, cheapest year first.
    public var ranked: [PricedPlan]
    /// Plans whose label could not be checked; shown with their published prices only.
    public var estimated: [FeedPlan]
    /// Time-of-use plans, which need hourly usage to price.
    public var timeOfUse: [FeedPlan]

    /// `profile` prices time-of-use plans; `hasSolar` leaves out those whose label excludes
    /// homes with solar.
    public init(feed: Feed, tdu: TDU, usage: YearOfUsage, filters: PlanFilters = PlanFilters(), profile: UsageProfile? = nil,
                hasSolar: Bool = false) {
        let area = feed.plans.filter { $0.offer.tdu == tdu && filters.allows($0) }
        var ranked: [PricedPlan] = []
        var estimated: [FeedPlan] = []
        var timeOfUse: [FeedPlan] = []
        for plan in area {
            switch plan.status {
            case .verified:
                guard let labelTerms = plan.terms else { estimated.append(plan); continue }
                let terms = PlanRanking.withCurrentDelivery(labelTerms, charges: feed.delivery(for: tdu))
                let bills = usage.kWh.map { CostEngine.monthlyBill(terms, kWh: $0) }
                let total = bills.reduce(0, +)
                ranked.append(PricedPlan(
                    plan: plan, terms: terms, annualCost: total,
                    averagePrice: usage.total > 0 ? total / usage.total * 100 : 0,
                    monthlyBills: bills,
                    warnings: TrapRules.warnings(for: plan.offer, terms: terms, monthlyKWh: usage.kWh, payment: plan.payment)
                ))
            case .estimated:
                estimated.append(plan)
            case .timeOfUse:
                if let profile, let tou = plan.timeOfUse, !(hasSolar && tou.excludesSolar),
                   let priced = PlanRanking.price(plan, tou.withDelivery(feed.delivery(for: tdu)), usage: usage, profile: profile) {
                    ranked.append(priced)
                } else {
                    timeOfUse.append(plan)
                }
            }
        }
        self.ranked = ranked.sorted { ($0.annualCost, $0.plan.offer.provider) < ($1.annualCost, $1.plan.offer.provider) }
        self.estimated = estimated.sorted { $0.offer.price1000 < $1.offer.price1000 }
        self.timeOfUse = timeOfUse.sorted { $0.offer.price1000 < $1.offer.price1000 }
    }

    /// A time-of-use plan priced month by month with the share of each month's usage that
    /// falls in each window. Only with a full year of time-of-day data: one month's pattern
    /// can't stand in for another's (summer air conditioning runs in the day).
    public static func price(_ plan: FeedPlan, _ tou: TimeOfUseTerms, usage: YearOfUsage, profile: UsageProfile) -> PricedPlan? {
        guard profile.isComplete else { return nil }
        let yearly: [Double] = tou.windows.map { w in
            var inside = 0.0, total = 0.0
            for m in 0..<12 {
                let s = profile.slots[m], monthTotal = s.reduce(0, +)
                guard monthTotal > 0, let share = profile.share(of: w, month: m + 1) else { continue }
                inside += share * usage.kWh[m]
                total += usage.kWh[m]
            }
            return total > 0 ? inside / total : 0
        }
        guard profile.slots.contains(where: { $0.reduce(0, +) > 0 }) else { return nil }
        var bills = (0..<12).map { m in
            tou.monthlyBill(kWh: usage.kWh[m], month: m + 1) { w in profile.share(of: w, month: m + 1) ?? 0 }
        }
        bills[0] += tou.oneTimeFee
        let total = bills.reduce(0, +)
        // A flat-rate equivalent for the rest of the app (switch timing, bill checks).
        let fixed = (tou.baseCharge + tou.deliveryPerMonth) * 12 + tou.oneTimeFee
        let effectiveEnergy = usage.total > 0 ? ((total - fixed) * 100 / usage.total) - tou.deliveryPerKWh : tou.energyRate
        // The one-time fee spread over the year, so switch timing and bill checks include it.
        let terms = PlanTerms(baseCharge: tou.baseCharge + tou.oneTimeFee / 12, energyRate: effectiveEnergy,
                              deliveryPerKWh: tou.deliveryPerKWh, deliveryPerMonth: tou.deliveryPerMonth)
        return PricedPlan(plan: plan, terms: terms, annualCost: total,
                          averagePrice: usage.total > 0 ? total / usage.total * 100 : 0, monthlyBills: bills,
                          warnings: TrapRules.warnings(for: plan.offer, terms: terms, monthlyKWh: usage.kWh, payment: plan.payment),
                          timeOfUse: tou, windowShares: yearly)
    }

    /// Delivery charges are passed through at whatever the TDU charges now, so a plan is
    /// priced with the current TDU table even if its label printed older figures. Plans
    /// whose energy charge already includes delivery (zero delivery) are left alone.
    public static func withCurrentDelivery(_ terms: PlanTerms, charges: TDUCharges?) -> PlanTerms {
        guard terms.deliveryPerKWh > 0 || terms.deliveryPerMonth > 0, let table = charges else { return terms }
        var t = terms
        t.deliveryPerKWh = table.perKWh
        t.deliveryPerMonth = table.perMonth
        return t
    }
}
