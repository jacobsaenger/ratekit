import Foundation

/// A time-of-use plan's charges: one energy rate, less a credit for usage inside each of
/// its time windows (free nights, free weekends, solar days).
///
/// Labels publish their average prices assuming a share of usage in each window, so a
/// reading is checked the same way as any plan: with those shares it must reproduce the
/// three prices on Power to Choose within 0.1¢.
public struct TimeOfUseTerms: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public enum Days: String, Codable, Sendable { case all, weekdays, weekends }

        public var name: String
        /// Minutes after midnight; the window runs from start up to (not including) end, and
        /// wraps past midnight when end ≤ start. 0 and 1440 mean all day.
        public var startMinute: Int
        public var endMinute: Int
        public var days: Days
        /// Months it applies in (1–12); nil for every month.
        public var months: [Int]?
        /// ¢ taken off each kWh used inside the window.
        public var credit: Double
        /// The share of usage the label assumes falls in the window (0–1).
        public var labelShare: Double

        public init(name: String, startMinute: Int, endMinute: Int, days: Days = .all, months: [Int]? = nil,
                    credit: Double, labelShare: Double) {
            self.name = name
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.days = days
            self.months = months
            self.credit = credit
            self.labelShare = labelShare
        }

        /// True for a 15-minute slot starting `minute` after midnight on that kind of day.
        public func contains(minute: Int, weekend: Bool, month: Int) -> Bool {
            if let months, !months.contains(month) { return false }
            switch days {
            case .weekdays where weekend, .weekends where !weekend: return false
            default: break
            }
            if startMinute == endMinute || (startMinute == 0 && endMinute >= 1440) { return true }
            return startMinute < endMinute ? (minute >= startMinute && minute < endMinute)
                                           : (minute >= startMinute || minute < endMinute)
        }
    }

    public var baseCharge: Double
    /// ¢/kWh before window credits.
    public var energyRate: Double
    public var windows: [Window]
    public var deliveryPerKWh: Double
    public var deliveryPerMonth: Double
    /// A one-time sign-up charge the label spreads over 12 months in its average prices.
    public var oneTimeFee: Double
    /// The label's eligibility exclusion, word for word ("Customers with electric vehicles,
    /// batteries, and/or solar panels are ineligible."), when it has one.
    public var eligibility: String?

    /// True when the label rules out homes with solar panels.
    public var excludesSolar: Bool { eligibility?.lowercased().contains("solar") ?? false }

    public init(baseCharge: Double, energyRate: Double, windows: [Window], deliveryPerKWh: Double,
                deliveryPerMonth: Double, oneTimeFee: Double = 0) {
        self.baseCharge = baseCharge
        self.energyRate = energyRate
        self.windows = windows
        self.deliveryPerKWh = deliveryPerKWh
        self.deliveryPerMonth = deliveryPerMonth
        self.oneTimeFee = oneTimeFee
    }

    /// The label's average price at `kWh`, with its assumed window shares.
    public func labelAveragePrice(kWh: Double) -> Double {
        let credits = windows.reduce(0) { $0 + $1.credit * kWh * $1.labelShare }
        let cents = baseCharge * 100 + deliveryPerMonth * 100 + kWh * (energyRate + deliveryPerKWh) - credits + oneTimeFee * 100 / 12
        return cents / kWh
    }

    /// A month's bill in dollars for `kWh`, with `share(window)` of it inside each window.
    ///
    /// A seasonal bonus on the same hours as a year-round window ("an additional 25% credit
    /// … during the Free Nights Savings period during July, August, and September") is capped
    /// at the energy charges outside that window ("will never exceed your total daytime
    /// energy charges"), and credits never take the energy charge below zero.
    public func monthlyBill(kWh: Double, month: Int, share: (Window) -> Double) -> Double {
        var credits = 0.0
        for w in windows where w.months?.contains(month) ?? true {
            var credit = w.credit * kWh * share(w)
            if w.months != nil, let base = windows.first(where: { $0.months == nil && $0.startMinute == w.startMinute
                                                                    && $0.endMinute == w.endMinute && $0.days == w.days }) {
                credit = min(credit, energyRate * kWh * (1 - share(base)))
            }
            credits += credit
        }
        credits = min(credits, energyRate * kWh)
        return (kWh * (energyRate + deliveryPerKWh) - credits) / 100 + baseCharge + deliveryPerMonth
    }

    /// Same energy charge, base charge and windows with the same credits.
    func sameCharges(as other: TimeOfUseTerms) -> Bool {
        abs(energyRate - other.energyRate) < 1e-6 && abs(baseCharge - other.baseCharge) < 1e-6 && windows.count == other.windows.count
            && zip(windows, other.windows).allSatisfy { a, b in
                a.name == b.name && a.startMinute == b.startMinute && a.endMinute == b.endMinute && a.days == b.days
                    && a.months == b.months && abs(a.credit - b.credit) < 1e-6
            }
    }

    public func withDelivery(_ charges: TDUCharges?) -> TimeOfUseTerms {
        guard deliveryPerKWh > 0 || deliveryPerMonth > 0, let charges else { return self }
        var t = self
        t.deliveryPerKWh = charges.perKWh
        t.deliveryPerMonth = charges.perMonth
        return t
    }
}

/// When in the day and week a household uses power: for each month, kWh in each
/// 15-minute slot of an average weekday and weekend day. Built from 15-minute meter data.
public struct UsageProfile: Codable, Equatable, Sendable {
    /// 12 months (January first) × 192 slots: 96 weekday slots, then 96 weekend slots.
    public var slots: [[Double]]

    public init(slots: [[Double]]) {
        precondition(slots.count == 12 && slots.allSatisfy { $0.count == 192 })
        self.slots = slots
    }

    /// The share of month `month` (1–12)'s usage inside `window`, or nil without data for it.
    public func share(of window: TimeOfUseTerms.Window, month: Int) -> Double? {
        let s = slots[month - 1]
        let total = s.reduce(0, +)
        guard total > 0 else { return nil }
        var inside = 0.0
        for i in 0..<192 where window.contains(minute: (i % 96) * 15, weekend: i >= 96, month: month) { inside += s[i] }
        return inside / total
    }

    /// True when every month has data.
    public var isComplete: Bool { slots.allSatisfy { $0.reduce(0, +) > 0 } }
}

/// Reads a time-of-use label: window names, hours, days and months; the share of usage the
/// label assumes in each; the credit or rate in each. Every combination the wording allows
/// is tried; the plan is read only when every combination that reproduces the published
/// prices gives the same charges.
public enum TimeOfUseReader {
    public static func read(_ offer: PlanOffer, labelText text: String) -> TimeOfUseTerms? {
        let flat = LabelParser.normalized(text).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let shares = labelShares(flat)
        guard !shares.isEmpty else { return nil }
        let facts = LabelParser.facts(fromLabel: text, tdu: offer.tdu, feesAndCredits: offer.feesAndCredits)
        let current = TDUCharges.current(offer.tdu)
        let deliveryK = facts.deliveryPerKWh.first ?? (facts.deliveryIncluded ? 0 : current?.perKWh ?? 0)
        let deliveryM = facts.deliveryPerMonth.first ?? (facts.deliveryIncluded ? 0 : current?.perMonth ?? 0)
        // The delivery charge is a ¢/kWh figure too, but never an energy rate.
        let rates = Array(Set(facts.energyRates + tableRates(flat))).filter { r in
            !facts.deliveryPerKWh.contains { abs($0 - r) < 1e-9 } && abs(r - deliveryK) > 1e-9
        }.sorted()
        let bases = facts.baseCharges.isEmpty ? [0] : Array(Set(facts.baseCharges + [0]))
        let oneTime = oneTimeFee(flat)

        var windows: [(TimeOfUseTerms.Window, [Double: Double])] = []   // window, credit options keyed by energy rate
        for (share, name) in shares {
            guard var window = window(named: name, in: flat, share: share) else { continue }
            window.credit = 0
            windows.append((window, [:]))
        }
        guard !windows.isEmpty else { return nil }

        // Every reading that reproduces the published prices; if they disagree about the
        // windows or credits, the label is ambiguous and the plan isn't priced.
        var passing: [TimeOfUseTerms] = []
        for energy in rates where energy > 0 {
            // Each window's credit: none, a stated percentage of the energy charge, all of
            // it, or down to one of the label's other rates.
            let options: [[Double]] = windows.map { w, _ in
                var o: Set<Double> = [0, energy]
                if let pct = creditPercent(for: w.name, in: flat) { o.insert(energy * pct) }
                for r in rates where r < energy { o.insert(energy - r) }
                return Array(o)
            }
            for credits in combinations(options) {
                for base in bases {
                    var ws = windows.map(\.0)
                    for i in ws.indices { ws[i].credit = credits[i] }
                    let terms = TimeOfUseTerms(baseCharge: base, energyRate: energy, windows: ws.filter { $0.credit > 0 },
                                               deliveryPerKWh: deliveryK, deliveryPerMonth: deliveryM, oneTimeFee: oneTime)
                    guard !terms.windows.isEmpty else { continue }
                    let miss = PlanVerifier.checkpoints.map { kWh in
                        abs(terms.labelAveragePrice(kWh: kWh) - (offer.publishedPrice(atKWh: Int(kWh)) ?? .infinity))
                    }.max() ?? .infinity
                    if miss <= verificationTolerance { passing.append(terms) }
                }
            }
        }
        guard var terms = passing.first,
              passing.allSatisfy({ $0.sameCharges(as: terms) }) else { return nil }
        terms.eligibility = eligibility(flat)
        return terms
    }

    // MARK: Shares

    /// "41.13% of electricity usage occurred during the Free Nights Savings period",
    /// "35% of the Average Monthly Use occurs during the Bright Nights hours",
    /// "an estimated 33% consumption during Day Hours", "30.0% of usage occurs during Weekends".
    static func labelShares(_ text: String) -> [(Double, String)] {
        var out: [(Double, String)] = []
        for m in text.matches(of: /(\d{1,2}(?:\.\d+)?)%[^%.]{0,70}?\bduring (?:the )?((?:[A-Z][A-Za-z]*)(?: [A-Z][A-Za-z]*){0,3})/) {
            guard let v = Double(m.1) else { continue }
            var name = String(m.2)
            for suffix in [" Period", " Hours", " period", " hours"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
            if !out.contains(where: { $0.1 == name }) { out.append((v / 100, name)) }
        }
        return out
    }

    // MARK: Windows

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                             "september", "october", "november", "december"]

    /// The window's hours, days and months from the text around its name.
    /// `inherit` lets a window take another window's hours (one level, so two windows that
    /// name each other can't loop).
    static func window(named name: String, in text: String, share: Double, inherit: Bool = true) -> TimeOfUseTerms.Window? {
        let lower = text.lowercased()
        let key = name.lowercased()
        let stem = key.hasSuffix("s") ? String(key.dropLast()) : key
        var days: TimeOfUseTerms.Window.Days = .all
        if stem.contains("weekend") { days = .weekends } else if stem.contains("weekday") { days = .weekdays }

        // Every place the name appears, up to 220 characters or the next window's own
        // definition ("Cool Summer Bonus:"), whichever comes first.
        let others = labelShares(text).map { $0.1.lowercased() }.filter { $0 != key }
        var spans: [Substring] = []
        var search = lower.startIndex
        while let r = lower.range(of: stem, range: search..<lower.endIndex) {
            var end = lower.index(r.lowerBound, offsetBy: 220, limitedBy: lower.endIndex) ?? lower.endIndex
            for o in others {
                if let d = lower.range(of: o + ":", range: r.upperBound..<end) { end = min(end, d.lowerBound) }
            }
            spans.append(lower[r.lowerBound..<end])
            search = r.upperBound
        }
        // In each place the name appears, a time range gives the hours, unless another
        // window's name comes first ("credit … during the Free Nights Savings period during
        // July…"): then this window has that one's hours.
        var hours: (Int, Int)?
        var defining: Substring?
        for span in spans {
            let afterName = span.dropFirst(stem.count)
            let rangeAt = afterName.firstRange(of: /(\d{1,2})(?::\d{2})?\s*[ap]\.?\s*m\.?\s*(?:to|through|thru|until|–|-)/)?.lowerBound
            let other = others.compactMap { o in afterName.range(of: o).map { (o, $0.lowerBound) } }.min { $0.1 < $1.1 }
            // A weekend or weekday window takes its days from its name, never from another.
            if inherit, days == .all, let other, rangeAt == nil || other.1 < rangeAt! {
                if let w = window(named: other.0, in: text, share: 0, inherit: false) {
                    hours = (w.startMinute, w.endMinute); days = w.days; defining = span; break
                }
            }
            if rangeAt != nil, let h = timeRange(String(afterName)) { hours = h; defining = span; break }
        }
        if hours == nil, days != .all { hours = (0, 1440) }
        guard let (start, end) = hours else { return nil }
        // Months only from the passage that defines the window, and only as a list ("July,
        // August, and September"), so a date or the word "may" isn't read as one.
        var months: [Int]?
        let month = "(january|february|march|april|may|june|july|august|september|october|november|december)"
        let list = try! NSRegularExpression(pattern: month + "(?:,? (?:and )?" + month + ")+")
        if let defining {
            let str = String(defining)
            if let m = list.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)), let r = Range(m.range, in: str) {
                months = monthNames.enumerated().filter { str[r].contains($0.element) }.map { $0.offset + 1 }
            }
        }
        return TimeOfUseTerms.Window(name: name, startMinute: start, endMinute: end, days: days, months: months,
                                     credit: 0, labelShare: share)
    }

    /// "9:00 p.m. through 4:59 a.m.", "11:00 PM to 06:00 AM", "9:00 AM – 4:00 PM".
    static func timeRange(_ text: String) -> (Int, Int)? {
        guard let m = text.firstMatch(of: /(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?\s*(to|through|thru|until|–|-)\s*(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?/) else { return nil }
        func minutes(_ h: Substring, _ mm: Substring?, _ ap: Substring) -> Int? {
            guard var hour = Int(h), hour >= 1, hour <= 12 else { return nil }
            if hour == 12 { hour = 0 }
            if ap == "p" { hour += 12 }
            return hour * 60 + (mm.flatMap { Int($0) } ?? 0)
        }
        guard let s = minutes(m.1, m.2, m.3), var e = minutes(m.5, m.6, m.7) else { return nil }
        // "through 4:59" includes that minute.
        if (m.4 == "through" || m.4 == "thru"), e % 60 == 59 { e = (e + 1) % 1440 }
        return (s, e)
    }

    // MARK: Credits and rates

    /// "100% credit on all Energy Charges", "an additional 25% credit": the share of the
    /// energy charge credited inside the named window.
    static func creditPercent(for name: String, in text: String) -> Double? {
        let lower = text.lowercased()
        var search = lower.startIndex
        while let r = lower.range(of: name.lowercased(), range: search..<lower.endIndex) {
            // The definition: "Name: … 100% credit", within the sentence after the name.
            let span = lower[r.upperBound..<(lower.index(r.upperBound, offsetBy: 90, limitedBy: lower.endIndex) ?? lower.endIndex)]
            if let m = span.firstMatch(of: /(\d{1,3})%\s+credit/), let v = Double(m.1), v > 0, v <= 100 { return v / 100 }
            search = r.upperBound
        }
        return nil
    }

    /// Rates in a weekday/weekend table: "Weekdays Weekends Base Charge 10.3¢/kWh 0.0¢/kWh $0.00".
    static func tableRates(_ text: String) -> [Double] {
        text.matches(of: /(\d{1,2}(?:\.\d+)?)\s*¢\s*\/?\s*kwh/.ignoresCase()).compactMap { Double($0.1) }.filter { $0 < 60 }
    }

    /// "One-time … set up …: $49.99 … 1/12 of this set up cost is included".
    static func oneTimeFee(_ text: String) -> Double {
        guard text.lowercased().contains("1/12 of"),
              let m = text.firstMatch(of: /[Oo]ne-time[^$]{0,80}\$(\d+(?:\.\d{2})?)/), let v = Double(m.1) else { return 0 }
        return v
    }

    /// "Customers with electric vehicles, batteries, and/or solar panels are ineligible."
    static func eligibility(_ text: String) -> String? {
        for sentence in text.components(separatedBy: ". ") {
            let lower = sentence.lowercased()
            if lower.contains("ineligible") || (lower.contains("not eligible") && !lower.contains("promotional")) {
                let s = sentence.trimmingCharacters(in: .whitespaces)
                return s.hasSuffix(".") ? s : s + "."
            }
        }
        return nil
    }

    static func combinations(_ options: [[Double]]) -> [[Double]] {
        options.reduce([[]]) { acc, choices in acc.flatMap { prefix in choices.map { prefix + [$0] } } }
    }
}
