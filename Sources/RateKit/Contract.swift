import Foundation

/// The household's current electricity plan, as they entered it.
public struct CurrentPlan: Codable, Equatable, Sendable {
    public var providerName: String
    public var planName: String
    public var endDate: Date
    /// Dollars to leave early (0 if none).
    public var cancelFee: Double
    /// When the plan was picked from the feed, its terms come from there.
    public var feedPlanID: String?
    /// Typed in from the bill or Facts label when the plan is not in the feed.
    public var energyRate: Double
    public var baseCharge: Double
    /// The typed-in rate is an all-in price that already includes delivery.
    public var includesDelivery: Bool?
    /// The plan the provider will move the household to when the contract ends, typed in
    /// from the expiration notice's Facts label (optional).
    public var renewalEnergyRate: Double?
    public var renewalBaseCharge: Double?
    public var renewalIncludesDelivery: Bool?

    public init(providerName: String, planName: String, endDate: Date, cancelFee: Double,
                feedPlanID: String? = nil, energyRate: Double = 0, baseCharge: Double = 0,
                includesDelivery: Bool = false) {
        self.providerName = providerName
        self.planName = planName
        self.endDate = endDate
        self.cancelFee = cancelFee
        self.feedPlanID = feedPlanID
        self.energyRate = energyRate
        self.baseCharge = baseCharge
        self.includesDelivery = includesDelivery
    }

    /// The plan's terms with the TDU's current delivery charges, or nil if it was picked
    /// from the feed and that plan is no longer listed or not verified. A one-time sign-up
    /// fee is left out: the household has already paid it (see `oneTimeFee(feed:)`).
    public func terms(tdu: TDU, feed: Feed?) -> PlanTerms? {
        if let id = feedPlanID {
            guard var listed = feed?.plans.first(where: { $0.id == id })?.terms else { return nil }
            listed.oneTimeFee = nil
            return PlanRanking.withCurrentDelivery(listed, charges: feed?.delivery(for: tdu))
        }
        return Self.typedTerms(energyRate: energyRate, baseCharge: baseCharge,
                               includesDelivery: includesDelivery == true, tdu: tdu, feed: feed)
    }

    /// The one-time sign-up fee of a plan picked from the feed, charged on its first bill.
    public func oneTimeFee(feed: Feed?) -> Double {
        guard let id = feedPlanID else { return 0 }
        return feed?.plans.first(where: { $0.id == id })?.terms?.oneTimeFee ?? 0
    }

    /// The renewal plan's terms, if its rate was entered.
    public func renewalTerms(tdu: TDU, feed: Feed?) -> PlanTerms? {
        guard let rate = renewalEnergyRate, rate > 0 else { return nil }
        return Self.typedTerms(energyRate: rate, baseCharge: renewalBaseCharge ?? 0,
                               includesDelivery: renewalIncludesDelivery == true, tdu: tdu, feed: feed)
    }

    static func typedTerms(energyRate: Double, baseCharge: Double, includesDelivery: Bool, tdu: TDU, feed: Feed?) -> PlanTerms {
        let none = TDUCharges(perKWh: 0, perMonth: 0)
        let delivery = includesDelivery ? none : (feed?.delivery(for: tdu) ?? TDUCharges.current(tdu) ?? none)
        return PlanTerms(baseCharge: baseCharge, energyRate: energyRate,
                         deliveryPerKWh: delivery.perKWh, deliveryPerMonth: delivery.perMonth)
    }
}

/// Reminders before a contract ends.
public struct ContractReminder: Equatable, Sendable {
    public var date: Date
    public var daysBefore: Int
    public var title: String
    public var body: String
}

public enum ReminderPlanner {
    public static let daysBefore = [60, 30, 14]

    /// Texas rules (16 TAC §25.475) bar a termination penalty for residential customers in
    /// the 14 days before the contract's expiration date.
    public static let feeFreeDays = 14

    /// Reminders at 9 a.m. local time 60, 30 and 14 days before `endDate`, skipping any
    /// already past.
    public static func reminders(for plan: CurrentPlan, now: Date, calendar: Calendar = .current) -> [ContractReminder] {
        let end = calendar.startOfDay(for: plan.endDate)
        return daysBefore.compactMap { days in
            guard let day = calendar.date(byAdding: .day, value: -days, to: end),
                  let at = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  at > now else { return nil }
            let name = plan.planName.isEmpty ? "Your electricity plan" : "Your \(plan.planName) plan"
            let body: String
            switch days {
            case feeFreeDays:
                body = "It ends in 14 days. You can switch now without a cancellation fee. Compare plans before it rolls onto the renewal rate."
            default:
                body = "It ends in \(days) days. Compare plans now so you don't roll onto the renewal rate."
            }
            return ContractReminder(date: at, daysBefore: days, title: "\(name) ends soon", body: body)
        }
    }
}

extension ReminderPlanner {
    /// Days after a new plan starts to check its first bill: long enough for one full
    /// billing cycle to be billed.
    public static let firstBillDays = 35

    /// "Check your first bill": after a switch, at 9 a.m., if still ahead.
    public static func firstBillCheck(planName: String, startedOn start: Date, now: Date,
                                      calendar: Calendar = .current) -> ContractReminder? {
        guard let day = calendar.date(byAdding: .day, value: firstBillDays, to: calendar.startOfDay(for: start)),
              let at = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day), at > now else { return nil }
        return ContractReminder(date: at, daysBefore: 0, title: "Check your first bill on \(planName)",
                                body: "Scan it to make sure you're being charged the rate you signed up for.")
    }

    /// Reminders after the contract has ended (1 and 7 days after), for a household that
    /// hasn't entered a new plan: it is most likely on the provider's month-to-month rate.
    public static let daysAfter = [1, 7]

    public static func afterEnd(for plan: CurrentPlan, now: Date, calendar: Calendar = .current) -> [ContractReminder] {
        let end = calendar.startOfDay(for: plan.endDate)
        return daysAfter.compactMap { days in
            guard let day = calendar.date(byAdding: .day, value: days, to: end),
                  let at = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  at > now else { return nil }
            let name = plan.planName.isEmpty ? "Your electricity plan" : "Your \(plan.planName) plan"
            let when = days == 1 ? "yesterday" : "a week ago"
            return ContractReminder(date: at, daysBefore: -days, title: "\(name) has ended",
                                    body: "It ended \(when). Unless you picked a new plan, you're on a month-to-month plan whose price can change every bill. You can switch with no fee.")
        }
    }
}

/// Whether switching to the best plan is worth an alert.
public enum AlertPlanner {
    public static let defaultThreshold = 100.0
    public static let minimumGap: TimeInterval = 7 * 24 * 3600

    /// True when the best plan saves at least `threshold` dollars a year (after the
    /// cancellation fee, if the contract still charges one) and no alert went out in the
    /// last 7 days.
    public static func shouldAlert(_ comparison: SwitchComparison, threshold: Double, lastAlert: Date?, now: Date) -> Bool {
        if let lastAlert, now.timeIntervalSince(lastAlert) < minimumGap { return false }
        return comparison.netFirstYearSaving >= threshold
    }
}

/// The household's current plan against the best ranked plan.
public struct SwitchComparison: Equatable, Sendable {
    public var currentAnnualCost: Double
    public var best: PricedPlan
    /// The fee due if switching today (0 inside the fee-free window or after the end date).
    public var cancelFeeNow: Double

    public var annualSaving: Double { currentAnnualCost - best.annualCost }
    public var netFirstYearSaving: Double { annualSaving - cancelFeeNow }

    public init?(current: CurrentPlan, terms: PlanTerms, usage: YearOfUsage, ranking: PlanRanking,
                 now: Date, calendar: Calendar = .current) {
        guard let best = ranking.ranked.first else { return nil }
        self.best = best
        self.currentAnnualCost = CostEngine.annualCost(terms, monthlyKWh: usage.kWh)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: current.endDate)).day ?? 0
        self.cancelFeeNow = days > ReminderPlanner.feeFreeDays ? current.cancelFee : 0
    }
}

/// Switch today (paying the cancellation fee) or wait for the fee-free window? Both are
/// costed over the same next 12 months.
public struct SwitchTiming: Equatable, Sendable {
    /// The first day a switch carries no cancellation fee.
    public var feeFreeDate: Date
    /// Both savings are against staying on the current rate for the whole 12 months.
    /// Dollars saved over the next 12 months by switching today, after the fee.
    public var switchNowSaving: Double
    /// Dollars saved over the next 12 months by staying until `feeFreeDate`, then switching.
    public var waitSaving: Double

    public var waitIsBetter: Bool { waitSaving > switchNowSaving }

    /// nil when there is no fee to avoid (none, or already inside the fee-free window).
    public init?(current: CurrentPlan, currentTerms: PlanTerms, best: PricedPlan, usage: YearOfUsage,
                 now: Date, calendar: Calendar = .current) {
        guard current.cancelFee > 0,
              let feeFree = calendar.date(byAdding: .day, value: -ReminderPlanner.feeFreeDays,
                                          to: calendar.startOfDay(for: current.endDate)),
              calendar.startOfDay(for: now) < feeFree,
              let yearOut = calendar.date(byAdding: .year, value: 1, to: calendar.startOfDay(for: now))
        else { return nil }
        let kWh = usage.kWh
        // The best plan's one-time fee is paid in full whenever the switch happens, not
        // spread over the months that remain.
        var bestTerms = best.terms
        let signUpFee = bestTerms.oneTimeFee ?? 0
        bestTerms.oneTimeFee = nil
        let stay = CostEngine.cost(currentTerms, monthlyKWh: kWh, from: now, to: yearOut, calendar: calendar)
        let switchNow = current.cancelFee + signUpFee
            + CostEngine.cost(bestTerms, monthlyKWh: kWh, from: now, to: yearOut, calendar: calendar)
        // A fee-free date more than a year out means waiting covers the whole 12 months.
        let waitEnd = min(feeFree, yearOut)
        let wait = CostEngine.cost(currentTerms, monthlyKWh: kWh, from: now, to: waitEnd, calendar: calendar)
            + (waitEnd < yearOut ? signUpFee : 0)
            + CostEngine.cost(bestTerms, monthlyKWh: kWh, from: waitEnd, to: yearOut, calendar: calendar)
        self.feeFreeDate = feeFree
        self.switchNowSaving = stay - switchNow
        self.waitSaving = stay - wait
    }
}

/// What staying put costs once the contract rolls onto the renewal rate.
public struct RenewalCheck: Equatable, Sendable {
    public var renewalAnnualCost: Double
    public var best: PricedPlan

    /// Dollars a year the renewal rate costs over the best plan.
    public var extraCost: Double { renewalAnnualCost - best.annualCost }

    public init?(renewalTerms: PlanTerms, usage: YearOfUsage, ranking: PlanRanking) {
        guard let best = ranking.ranked.first else { return nil }
        self.best = best
        self.renewalAnnualCost = CostEngine.annualCost(renewalTerms, monthlyKWh: usage.kWh)
    }
}
