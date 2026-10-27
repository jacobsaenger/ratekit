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

    /// Twelve months or longer by default. A shorter fixed plan's yearly cost covers its
    /// term and then switching again to the cheapest 12-month plan (`PricedPlan.afterTerm`).
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
    /// Only plans priced one simple way: a fixed rate with one energy price and no bill
    /// credits, minimum-usage fees, time-of-day pricing, one-time fees, prepaid billing or
    /// autopay/paperless condition, so they compare apples to apples. A plan whose label
    /// couldn't be checked can't be shown to be simple, so it's hidden too.
    public var simplePlansOnly = false
    /// Only these providers (`PlanOffer.provider`); empty shows every provider.
    public var providers: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case term, fixedRateOnly, minimumRenewablePercent, hidePrepaid, hideMinimumUsageFees
        case solarBuybackOnly, hideHighComplaintProviders, hidePaymentRequirements, simplePlansOnly, providers
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
        simplePlansOnly = try c.decodeIfPresent(Bool.self, forKey: .simplePlansOnly) ?? false
        providers = try c.decodeIfPresent(Set<String>.self, forKey: .providers) ?? []
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
        if simplePlansOnly && !Self.isSimple(plan) { return false }
        if !providers.isEmpty && !providers.contains(o.provider) { return false }
        return true
    }

    static func isSimple(_ plan: FeedPlan) -> Bool {
        let o = plan.offer
        guard let t = plan.terms, plan.status == .verified, o.fixedRate, !o.prepaid, !o.timeOfUse, plan.payment == nil
        else { return false }
        return t.energyTiers.count == 1 && t.credits.isEmpty && t.minimumUsageFees.isEmpty && (t.oneTimeFee ?? 0) == 0
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
    /// Set for a fixed plan shorter than a year: the months after its term are priced as
    /// switching again to `afterTerm.plan`, the cheapest plan of 12 months or longer for
    /// this household.
    public var afterTerm: AfterTerm? = nil

    public var id: String { plan.id }

    public struct AfterTerm: Equatable, Sendable {
        public var plan: FeedPlan
        /// `plan`'s terms with current delivery and without its one-time fee, which is
        /// `signUpFee`, paid once on switching.
        public var terms: PlanTerms
        public var signUpFee: Double
        /// Months of the year after this plan's term.
        public var months: Int
        /// What those months cost on `plan`, its sign-up fee included, dollars.
        public var cost: Double
    }
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
    /// homes with solar. `startMonth` (1 = January) is the first month of the year a short
    /// plan is priced over: its term runs from there.
    public init(feed: Feed, tdu: TDU, usage: YearOfUsage, filters: PlanFilters = PlanFilters(), profile: UsageProfile? = nil,
                hasSolar: Bool = false, startMonth: Int = Calendar.current.component(.month, from: Date())) {
        // Providers picked in another area that have no plans here are ignored, so a move
        // doesn't leave an empty list.
        var filters = filters
        if !filters.providers.isEmpty {
            let here = Set(feed.plans.filter { $0.offer.tdu == tdu }.map(\.offer.provider))
            filters.providers.formIntersection(here)
        }
        let area = feed.plans.filter { $0.offer.tdu == tdu && filters.allows($0) }
        // Where a short plan's household goes when its term ends: today's cheapest verified
        // plan of 12 months or longer in the area, whatever the filters. Its one-time fee is
        // kept apart: it's paid once, on switching.
        let next = feed.plans
            .filter { $0.offer.tdu == tdu && $0.offer.termMonths >= 12 && $0.status == .verified && $0.terms != nil }
            .map { plan -> (plan: FeedPlan, terms: PlanTerms, fee: Double, bills: [Double]) in
                var terms = PlanRanking.withCurrentDelivery(plan.terms!, charges: feed.delivery(for: tdu))
                let fee = terms.oneTimeFee ?? 0
                terms.oneTimeFee = nil
                return (plan, terms, fee, usage.kWh.map { CostEngine.monthlyBill(terms, kWh: $0) })
            }
            .min { a, b in
                let costA: Double = a.bills.reduce(0, +) + a.fee, costB: Double = b.bills.reduce(0, +) + b.fee
                return (costA, a.plan.offer.provider) < (costB, b.plan.offer.provider)
            }
        var ranked: [PricedPlan] = []
        var estimated: [FeedPlan] = []
        var timeOfUse: [FeedPlan] = []
        for plan in area {
            switch plan.status {
            case .verified:
                guard let labelTerms = plan.terms else { estimated.append(plan); continue }
                let terms = PlanRanking.withCurrentDelivery(labelTerms, charges: feed.delivery(for: tdu))
                var bills = usage.kWh.map { CostEngine.monthlyBill(terms, kWh: $0) }
                var afterTerm: PricedPlan.AfterTerm?
                let term = plan.offer.termMonths
                if plan.offer.fixedRate, (1..<12).contains(term), let next {
                    // The year runs from `startMonth`; months past the term are on the next
                    // plan. Each plan's one-time fee is paid once, in its first month.
                    var own = terms
                    own.oneTimeFee = nil
                    bills = usage.kWh.map { CostEngine.monthlyBill(own, kWh: $0) }
                    bills[startMonth - 1] += terms.oneTimeFee ?? 0
                    let later = (term..<12).map { (startMonth - 1 + $0) % 12 }
                    for m in later { bills[m] = next.bills[m] }
                    bills[later[0]] += next.fee
                    afterTerm = .init(plan: next.plan, terms: next.terms, signUpFee: next.fee, months: later.count,
                                      cost: later.map { bills[$0] }.reduce(0, +))
                }
                let total = bills.reduce(0, +)
                ranked.append(PricedPlan(
                    plan: plan, terms: terms, annualCost: total,
                    averagePrice: usage.total > 0 ? total / usage.total * 100 : 0,
                    monthlyBills: bills,
                    warnings: TrapRules.warnings(for: plan.offer, terms: terms, monthlyKWh: usage.kWh, payment: plan.payment),
                    afterTerm: afterTerm
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
