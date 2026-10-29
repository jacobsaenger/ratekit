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

    /// The household's price target: true when the best plan's average price for its usage
    /// (¢ per kWh, delivery included) is at or under `target`, it's a new low since the last
    /// price alert (`lastAlertPrice`, cleared once prices go back over the target), and no
    /// price alert went out in the last 7 days. The same price is never reported twice.
    public static func shouldAlertPrice(bestAveragePrice: Double?, target: Double, lastAlert: Date?,
                                        lastAlertPrice: Double?, now: Date) -> Bool {
        guard let bestAveragePrice, bestAveragePrice <= target else { return false }
        if let lastAlertPrice, bestAveragePrice > lastAlertPrice - 0.05 { return false }
        if let lastAlert, now.timeIntervalSince(lastAlert) < minimumGap { return false }
        return true
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
        /// The best plan from `start` to `yearOut`: a short plan for its term, then the plan
        /// `afterTerm` names, as the ranking prices it.
        func onBest(from start: Date) -> Double {
            guard start < yearOut else { return 0 }
            var cost = signUpFee
            var termEnd = yearOut
            if let after = best.afterTerm,
               let end = calendar.date(byAdding: .month, value: best.plan.offer.termMonths, to: start), end < yearOut {
                termEnd = end
                cost += after.signUpFee + CostEngine.cost(after.terms, monthlyKWh: kWh, from: end, to: yearOut, calendar: calendar)
            }
            return cost + CostEngine.cost(bestTerms, monthlyKWh: kWh, from: start, to: termEnd, calendar: calendar)
        }
        let stay = CostEngine.cost(currentTerms, monthlyKWh: kWh, from: now, to: yearOut, calendar: calendar)
        let switchNow = current.cancelFee + onBest(from: now)
        // A fee-free date more than a year out means waiting covers the whole 12 months.
        let waitEnd = min(feeFree, yearOut)
        let wait = CostEngine.cost(currentTerms, monthlyKWh: kWh, from: now, to: waitEnd, calendar: calendar)
            + onBest(from: waitEnd)
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

/// What a switch saves: the new plan against staying on the old one, for the household's
/// usage, from the day the new plan started. Kept from the day of the switch, so it doesn't
/// depend on either plan still being listed.
public struct SwitchSavings: Codable, Equatable, Sendable {
    public var oldPlanName: String
    /// The old plan's terms, with the delivery charges of the day of the switch.
    public var oldTerms: PlanTerms
    public var oldEnds: Date
    /// What the old plan would have renewed at, if the renewal rate was entered.
    public var oldRenewalTerms: PlanTerms?
    public var newPlanName: String
    public var newTerms: PlanTerms
    public var start: Date
    public var newEnds: Date
    /// Paid once to switch: the old plan's cancellation fee, if one was due, and the new
    /// plan's sign-up fee.
    public var switchingCost: Double

    /// `oldCancelFee` counts if the new plan starts before the old plan's fee-free window.
    /// A one-time fee in `newTerms` is moved into the switching cost.
    public init(oldPlanName: String, oldTerms: PlanTerms, oldEnds: Date, oldCancelFee: Double, oldRenewalTerms: PlanTerms?,
                newPlanName: String, newTerms: PlanTerms, start: Date, newEnds: Date, calendar: Calendar = .current) {
        let feeFree = calendar.date(byAdding: .day, value: -ReminderPlanner.feeFreeDays, to: calendar.startOfDay(for: oldEnds)) ?? oldEnds
        var newTerms = newTerms
        let signUpFee = newTerms.oneTimeFee ?? 0
        newTerms.oneTimeFee = nil
        var oldTerms = oldTerms
        oldTerms.oneTimeFee = nil
        self.oldPlanName = oldPlanName
        self.oldTerms = oldTerms
        self.oldEnds = oldEnds
        self.oldRenewalTerms = oldRenewalTerms
        self.newPlanName = newPlanName
        self.newTerms = newTerms
        self.start = start
        self.newEnds = newEnds
        self.switchingCost = signUpFee + (calendar.startOfDay(for: start) < feeFree ? oldCancelFee : 0)
    }

    /// The comparison runs to the new contract's end, or, without the old plan's renewal
    /// rate, only to when the old contract would have ended: what it would have charged
    /// after that isn't known.
    public var comparisonEnd: Date { oldRenewalTerms == nil ? min(newEnds, oldEnds) : newEnds }

    /// A comparison shorter than this says little beyond the switching fees.
    public static let minimumComparison: TimeInterval = 30 * 86400

    /// False when there's too little to compare: without a renewal rate entered, the old
    /// contract had already ended or had less than a month left.
    public var isComparable: Bool { comparisonEnd.timeIntervalSince(start) >= Self.minimumComparison }

    /// Dollars saved from the start up to `date` (at most `comparisonEnd`): the old plan, on
    /// its renewal rate once its contract would have ended, against the new plan and the
    /// switching cost. Negative when the switch cost more. Nil before the new plan starts.
    public func saved(monthlyKWh: [Double], through date: Date, calendar: Calendar = .current) -> Double? {
        guard monthlyKWh.count == 12, date >= start else { return nil }
        let end = min(date, comparisonEnd)
        let oldSwitch = max(start, min(oldEnds, end))
        let old = CostEngine.cost(oldTerms, monthlyKWh: monthlyKWh, from: start, to: oldSwitch, calendar: calendar)
            + CostEngine.cost(oldRenewalTerms ?? oldTerms, monthlyKWh: monthlyKWh, from: oldSwitch, to: end, calendar: calendar)
        let new = CostEngine.cost(newTerms, monthlyKWh: monthlyKWh, from: start, to: end, calendar: calendar)
        return old - new - switchingCost
    }

    /// Dollars saved over the whole comparison, at the household's usage.
    public func savedOverall(monthlyKWh: [Double], calendar: Calendar = .current) -> Double? {
        saved(monthlyKWh: monthlyKWh, through: comparisonEnd, calendar: calendar)
    }
}
