import Foundation

/// The price figures found on an Electricity Facts Label, sorted by what the label's
/// wording says they are. Cents per kWh and dollars per month.
public struct LabelFacts: Equatable, Sendable {
    public var energyRates: [Double] = []
    public var baseCharges: [Double] = []
    public var deliveryPerKWh: [Double] = []
    public var deliveryPerMonth: [Double] = []
    public var credits: [UsageCredit] = []
    public var minimumUsageFees: [MinimumUsageFee] = []
    /// Energy rates that apply from a kWh level upward ("1001 kWh and above: 12¢").
    public var tiers: [EnergyTier] = []
    /// "The Energy Charge is only applicable to usage above N kWh."
    public var energyOnlyAboveKWh: Double?
    /// "Recurring TDSP delivery charges are included in the bundled price."
    public var deliveryIncluded = false
    /// A one-time enrollment charge the label spreads over 12 months in its averages.
    public var oneTimeFee: Double = 0
    /// Credit or fee wording the reader could not pin down. A plan with any is never
    /// verified: Power to Choose's three prices cannot catch a misread usage limit.
    public var unclear: [String] = []

    public init() {}
}

/// Reads `pdftotext -layout` output of a Facts label into `LabelFacts`, then proposes
/// the few `PlanTerms` those facts allow. Nothing here is fitted to the published
/// prices: every number comes from the label (or, for delivery, the TDU's tariff).
public enum LabelParser {
    // MARK: Reading

    public static func facts(fromLabel text: String, tdu: TDU, feesAndCredits: String = "") -> LabelFacts {
        var facts = LabelFacts()
        facts.oneTimeFee = TimeOfUseReader.oneTimeFee(normalized(text))
        let lines = priceSection(normalized(text))
        let table = TDUCharges.current(tdu)
        var lastClass: LineClass? = nil

        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            let located = Amount.locate(line)
            let amounts = located.map(\.amount)

            // "The Energy Charge is only applicable to usage above 1000 kWh"
            if lower.contains("energy charge"), lower.contains("only"),
               let k = firstKWh(after: ["above", "over", "exceed"], in: lower) {
                facts.energyOnlyAboveKWh = k
            }

            if lower.contains("included in the bundled price") || lower.contains("delivery charges are included") {
                facts.deliveryIncluded = true
            }

            // A row of three or more bare ¢ figures is the average-price row. Some labels
            // put the plan's rate in front of the averages ("TNMP 18.24¢ 20.6¢ 19.4¢ 18.8¢").
            if amounts.count >= 3, amounts.allSatisfy({ $0.unit == .cents }),
               !lower.contains("per kwh"), !lower.contains("/kwh") {
                if amounts.count >= 4 { facts.energyRates.append(amounts[0].value) }
                lastClass = nil
                continue
            }

            if isExcludedLine(lower) { lastClass = nil; continue }
            guard !located.isEmpty else {
                if let c = classify(lower) { lastClass = c }
                continue
            }

            // Each figure takes its meaning from the words just before it: two-column
            // layouts and sentences put several kinds of charge on one line.
            let chars = Array(lower)
            var previousEnd = 0
            var previousClass: LineClass? = nil
            for (index, item) in located.enumerated() {
                let prefix = String(chars[previousEnd..<item.start])
                // A credit or fee's limits come from its own clause: from the previous
                // figure (or ";") to the next one. A line with one figure may continue
                // onto the next lines.
                let context = located.count == 1
                    ? ownSentence(lines, at: i)
                    : clause(chars, around: item, previousEnd: previousEnd,
                             nextStart: index + 1 < located.count ? located[index + 1].start : chars.count)
                previousEnd = item.end
                var cls = classify(prefix) ?? previousClass
                // "$60 for 2100 kWh or more; $30 for 1100-1900 kWh": the second figure is
                // another credit, not a charge, when its words name no charge of their own.
                if let previous = previousClass, previous == .credit || previous == .minimumFee,
                   cls == .supply, !namesACharge(prefix) {
                    cls = previous
                }
                if cls == nil, index == 0 {
                    // A row that starts with a figure: a credit or fee says so after the
                    // figure ("$125 credit when…"); a table row of several figures is the
                    // plan's own charges; anything else continues the row above.
                    let lineClass = classify(lower)
                    if lineClass == .credit || lineClass == .minimumFee {
                        cls = lineClass
                    } else {
                        cls = located.count >= 3 ? .supply : (lastClass ?? lineClass)
                    }
                }
                previousClass = cls
                guard let cls, cls != .excluded else { continue }
                record(item.amount, as: cls, amountsOnLine: amounts, line: lower, context: context, table: table, into: &facts)
            }
            lastClass = previousClass == .excluded ? nil : previousClass
        }

        // The Power to Choose row restates the main credit in words: use it when the
        // label's own wording was not recognised, and treat a disagreement as unclear.
        if !feesAndCredits.isEmpty {
            let lower = normalized(feesAndCredits).lowercased()
            if lower.contains("credit"),
               let a = Amount.scan(lower).first(where: { $0.unit == .dollars && $0.value > 0 }),
               let c = credit(amount: a.value, context: lower), c.minKWh > 0 || c.maxKWh != nil {
                if facts.credits.isEmpty {
                    facts.credits.append(c)
                } else if let same = facts.credits.first(where: { $0.amount == c.amount }), same != c {
                    facts.unclear.append("credit limits differ from Power to Choose's description")
                }
            }
        }
        return facts
    }

    private static func record(_ a: Amount, as cls: LineClass, amountsOnLine amounts: [Amount], line lower: String,
                               context: String, table: TDUCharges?, into facts: inout LabelFacts) {
        switch cls {
        case .excluded:
            break
        case .credit:
            if a.unit == .dollars && a.value > 0 {
                if let c = credit(amount: a.value, context: context) {
                    facts.credits.append(c)
                } else {
                    facts.unclear.append("credit: \(context)")
                }
            }
        case .minimumFee:
            if a.unit == .dollars && a.value > 0 {
                if let below = threshold(below: context) {
                    facts.minimumUsageFees.append(MinimumUsageFee(amount: a.value, belowKWh: below))
                } else {
                    facts.unclear.append("fee: \(context)")
                }
            }
        case .delivery:
            switch a.unit {
            case .cents: facts.deliveryPerKWh.append(a.value)
            case .dollars: facts.deliveryPerMonth.append(a.value)
            }
        case .supply:
            switch a.unit {
            case .cents:
                let centsOnLine = amounts.filter { $0.unit == .cents }.count
                if let t = table, abs(a.value - t.perKWh) < 0.00005
                    || (centsOnLine > 1 && abs(a.value - t.perKWh) / t.perKWh < 0.03) {
                    // In a table row with several rates, the one beside the TDU's
                    // figure is its delivery charge, even if printed slightly differently.
                    facts.deliveryPerKWh.append(a.value)
                } else if let from = tierStart(lower) {
                    facts.tiers.append(EnergyTier(fromKWh: from, rate: a.value))
                } else {
                    facts.energyRates.append(a.value)
                }
            case .dollars:
                if let t = table, amounts.count > 2, abs(a.value - t.perMonth) < 0.005, t.perMonth > 0 {
                    facts.deliveryPerMonth.append(a.value)
                } else {
                    facts.baseCharges.append(a.value)
                }
            }
        }
    }

    // MARK: Candidate terms

    /// Plausible readings of the facts, most literal first.
    public static func candidates(from facts: LabelFacts, tdu: TDU) -> [PlanTerms] {
        let table = TDUCharges.current(tdu)

        var energyOptions: [[EnergyTier]] = []
        let rates = unique(facts.energyRates)
        if let above = facts.energyOnlyAboveKWh, let r = rates.first {
            energyOptions.append([EnergyTier(fromKWh: 0, rate: 0), EnergyTier(fromKWh: above, rate: r)])
        }
        if !facts.tiers.isEmpty {
            var tiers = facts.tiers.sorted { $0.fromKWh < $1.fromKWh }
            if tiers[0].fromKWh > 0, let r = rates.first { tiers.insert(EnergyTier(fromKWh: 0, rate: r), at: 0) }
            if tiers[0].fromKWh == 0 { energyOptions.append(tiers) }
        }
        for r in rates { energyOptions.append([EnergyTier(fromKWh: 0, rate: r)]) }
        if rates.count > 1 { energyOptions.append([EnergyTier(fromKWh: 0, rate: rates.reduce(0, +))]) }
        if energyOptions.isEmpty { return [] }

        var baseOptions = unique(facts.baseCharges)
        if baseOptions.count > 1 { baseOptions.append(baseOptions.reduce(0, +)) }
        if !baseOptions.contains(0) { baseOptions.append(0) }

        var deliveryOptions: [(Double, Double)] = []
        let perKWh = unique(facts.deliveryPerKWh), perMonth = unique(facts.deliveryPerMonth)
        for k in perKWh {
            deliveryOptions.append((k, perMonth.first ?? table?.perMonth ?? 0))
        }
        if facts.deliveryIncluded { deliveryOptions.insert((0, 0), at: 0) }
        if let t = table, !deliveryOptions.contains(where: { $0 == (t.perKWh, t.perMonth) }) {
            deliveryOptions.append((t.perKWh, t.perMonth))
        }
        // Power to Choose prices a provider hasn't updated since the TDU's last change.
        if let p = TDUCharges.previous(tdu), !deliveryOptions.contains(where: { $0 == (p.perKWh, p.perMonth) }) {
            deliveryOptions.append((p.perKWh, p.perMonth))
        }
        // Last: the energy charge already includes delivery (TriEagle and TXU print "**" for
        // the TDU rows). It can only verify if the label's own figures alone match.
        if !deliveryOptions.contains(where: { $0 == (0, 0) }) { deliveryOptions.append((0, 0)) }

        let creditOptions: [[UsageCredit]] = facts.credits.isEmpty ? [[]] : [facts.credits, []]
        let feeOptions: [[MinimumUsageFee]] = facts.minimumUsageFees.isEmpty ? [[]] : [facts.minimumUsageFees, []]

        var out: [PlanTerms] = []
        for energy in energyOptions {
            for delivery in deliveryOptions {
                for base in baseOptions {
                    for credits in creditOptions {
                        for fees in feeOptions {
                            out.append(PlanTerms(
                                baseCharge: base, energyTiers: energy,
                                deliveryPerKWh: delivery.0, deliveryPerMonth: delivery.1,
                                credits: credits, minimumUsageFees: fees,
                                oneTimeFee: facts.oneTimeFee > 0 ? facts.oneTimeFee : nil
                            ))
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: Text handling

    static func normalized(_ text: String) -> String {
        var t = text
        let replacements: [(String, String)] = [
            ("\u{00A0}", " "), ("\u{200B}", ""), ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2013}", "-"), ("\u{2014}", "-"),
            ("≥", ">="), ("≤", "<="), ("￠", "¢"),
        ]
        for (a, b) in replacements { t = t.replacingOccurrences(of: a, with: b) }
        // "4.691 cents/kWh" → "4.691¢/kWh"; "6.19¢ ¢ per kWh" → "6.19¢ per kWh"
        t = t.replacingOccurrences(of: #"(\d)\s*cents?\b"#, with: "$1¢", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"¢\s*¢"#, with: "¢", options: .regularExpression)
        // "1,000 kWh" → "1000 kWh"
        t = t.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        // "(¢)" and "($)" column hints carry no number.
        t = t.replacingOccurrences(of: #"\((?:¢|\$)\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return t
    }

    /// The lines that describe price, stopping at the terms-and-questions chart.
    static func priceSection(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let stop = lines.firstIndex { line in
            let l = line.lowercased()
            return l.hasPrefix("type of product") || l.contains("contract term ") || l.hasPrefix("other key")
                || l.hasPrefix("disclosure chart") || l.contains("promedi") || l.hasPrefix("tipo de producto")
        }
        // The min-usage fee and credit sentences sometimes sit just after the stop line.
        return Array(lines[..<(stop ?? lines.count)]) + trailingFeeLines(lines, from: stop)
    }

    private static func trailingFeeLines(_ lines: [String], from stop: Int?) -> [String] {
        guard let stop else { return [] }
        return lines[stop...].prefix(40).filter {
            let l = $0.lowercased()
            return l.contains("minimum usage") || (l.contains("usage") && l.contains("less than") && l.contains("$"))
        }
    }

    enum LineClass: Equatable { case excluded, credit, minimumFee, delivery, supply }

    /// Lines about fees and terms that never hold a recurring price.
    static func isExcludedLine(_ l: String) -> Bool {
        let excluded = [
            "statewide", "termination", "terminating", "cancel", "early exit", "exit fee", "deposit", "late fee",
            "returned", "reconnect", "disconnect", "insufficient", "processing fee", "past due", "penalty",
            "not enrolled", "if you are not", "one-time", "one time", "set up", "setup", "product change", "per esi",
            "remaining", "licen", "puct #", "puc #", "address", "phone", "www.", "http", "underground",
            "gross receipt", "breakage", "paper bill", "payment", "credit card", "service order", "switch fee",
            "move-in", "balance", "historical", "{calc}", "carbon credit",
        ]
        return excluded.contains(where: l.contains)
    }

    static func classify(_ l: String) -> LineClass? {
        // The average-price row's own label; text after it on the line may still be a charge.
        let averages = ["average price", "average monthly", "avg price", "price per kwh", "average usage", "late "]
        if averages.contains(where: l.contains) || isExcludedLine(l) { return .excluded }
        if l.contains("minimum usage") || l.contains("minimum monthly") || (l.contains("fee") && (l.contains("less than") || l.contains("below"))) {
            return .minimumFee
        }
        if ["credit", "bonus", "rebate", "discount", "reward"].contains(where: l.contains) { return .credit }
        let delivery = [
            "deliver", "tdu", "tdsp", "tdsp", "transmission", "distribution", "pass-through", "pass through",
            "pass thru", "passthrough", "oncor", "centerpoint", "center point", "aep", "tnmp", "texas-new mexico",
            "texas new mexico", "nueces electric", "lubbock", "lp&l", "lpl ", "utility charge", "customer charge", "wires",
        ]
        if delivery.contains(where: l.contains) { return .delivery }
        let supply = [
            "energy", "usage charge", "base", "charge", "rate", "fee", "price", "kwh", "per month",
            "billing cycle", "bill month", "contract price",
        ]
        if supply.contains(where: l.contains) {
            // A bare unit row ("$3.24 per month", "5.6898 ¢ per kWh") names no charge.
            let words = l.replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
                .split(separator: " ").map(String.init)
            let unitWords: Set<String> = ["per", "month", "kwh", "billing", "cycle", "bill", "and", "plus", "kilowatt", "hour", "charges"]
            if words.allSatisfy(unitWords.contains) { return nil }
            return .supply
        }
        return nil
    }

    /// The line holding a credit or fee, continued onto the next line or two only when it
    /// names no kWh yet and the continuation holds no other charge.
    static func ownSentence(_ lines: [String], at i: Int) -> String {
        var text = lines[i].lowercased()
        var next = i + 1
        while !text.contains("kwh"), next < lines.count, next <= i + 2 {
            let more = lines[next].lowercased()
            if more.contains("$") || more.contains("¢") { break }
            text += " " + more
            next += 1
        }
        return text
    }

    /// The part of a line belonging to one figure: from the previous figure's end (or the
    /// last ";" before this figure) to the next figure's start (or the first ";" after it).
    static func clause(_ chars: [Character], around item: Amount.Located, previousEnd: Int, nextStart: Int) -> String {
        var start = previousEnd
        if let semi = chars[previousEnd..<item.start].lastIndex(of: ";") { start = semi + 1 }
        var end = nextStart
        if let semi = chars[item.end..<nextStart].firstIndex(of: ";") { end = semi }
        return String(chars[start..<end])
    }

    /// Words that name a charge of their own (rather than only a usage limit).
    static func namesACharge(_ text: String) -> Bool {
        ["charge", "base", "energy", "deliver", "tdu", "tdsp", "fee", "rate", "price", "credit", "discount", "bonus"]
            .contains(where: text.contains)
    }

    /// A credit of `amount` with the usage limits its sentence gives; nil when the
    /// limits are contradictory or a kWh figure has no clear comparison.
    static func credit(amount: Double, context: String) -> UsageCredit? {
        guard let b = UsageLimits(context) else { return nil }
        return UsageCredit(amount: amount, minKWh: b.min ?? 0, maxKWh: b.max)
    }

    /// The kWh below which a minimum-usage fee applies; nil when the sentence does not
    /// say clearly.
    static func threshold(below context: String) -> Double? {
        guard let b = UsageLimits(context), b.min == nil, let max = b.max else { return nil }
        return max + 1
    }

    /// "between 1000 and 2000 kWh", "1000-2000 kWh", "1000 kWh to 2000 kWh"
    static func range(in s: String) -> (Double, Double)? {
        let patterns = [
            #"between (\d+) ?(?:kwh)? and (\d+) ?kwh"#,
            #"(\d+) ?(?:kwh)? ?(?:-|to|through) ?(\d+) ?kwh"#,
        ]
        for p in patterns {
            if let m = s.firstMatch(of: try! Regex(p)), let a = Double(m.output[1].substring!), let b = Double(m.output[2].substring!), b > a {
                return (a, b)
            }
        }
        return nil
    }

    static func firstKWh(after words: [String], in s: String) -> Double? {
        var best: (String.Index, Double)? = nil
        for w in words {
            let escaped = NSRegularExpression.escapedPattern(for: w)
            guard let regex = try? Regex(escaped + #"\s*(?:to\s*)?(\d+(?:\.\d+)?)\s*(?:kwh|kilowatt)"#) else { continue }
            if let m = s.firstMatch(of: regex), let v = Double(m.output[1].substring!) {
                if best == nil || m.range.lowerBound < best!.0 { best = (m.range.lowerBound, v) }
            }
        }
        return best?.1
    }

    static func firstKWh(before words: [String], in s: String) -> Double? {
        for w in words {
            let escaped = NSRegularExpression.escapedPattern(for: w)
            if let regex = try? Regex(#"(\d+(?:\.\d+)?)\s*kwh\s*"# + escaped),
               let m = s.firstMatch(of: regex), let v = Double(m.output[1].substring!) {
                return v
            }
        }
        return nil
    }

    /// "1001 kWh and above", "> 1000 kWh", "over 1000 kWh" on an energy row.
    static func tierStart(_ l: String) -> Double? {
        if let m = l.firstMatch(of: /(\d+)\s*\+\s*kwh/), let k = Double(m.1) { return k }
        if let k = firstKWh(before: ["and above", "and over", "or more", "+"], in: l) { return k }
        if let k = firstKWh(after: ["above", "over", "greater than", ">", "exceeding"], in: l) { return k }
        if let (lo, _) = range(in: l) { return lo == 1 ? 0 : lo }
        return nil
    }

    static func unique(_ values: [Double]) -> [Double] {
        var out: [Double] = []
        for v in values where !out.contains(where: { abs($0 - v) < 0.00001 }) { out.append(v) }
        return out
    }
}

/// A money figure on a label line.
struct Amount: Equatable {
    enum Unit { case cents, dollars }
    var value: Double
    var unit: Unit

    /// A figure and the character range it occupies on its line.
    struct Located {
        var amount: Amount
        var start: Int
        var end: Int
    }

    static func scan(_ line: String) -> [Amount] { locate(line).map(\.amount) }

    /// Finds money figures in order of appearance. Dollars-per-kWh become cents; a
    /// daily charge becomes 30 days.
    static func locate(_ line: String) -> [Located] {
        var s = line
        var found: [Located] = []
        let rules: [(String, (Double) -> Amount)] = [
            (#"\$\s*(\d+(?:\.\d+)?)\s*¢?\s*(?:per|/|a)\s*day"#, { Amount(value: $0 * 30, unit: .dollars) }),
            (#"\$\s*(\d*\.\d+)\s*(?:per|/)\s*(?:kwh|kilowatt)"#, { Amount(value: $0 * 100, unit: .cents) }),
            (#"\$\s*(-?\d+(?:\.\d+)?)"#, { Amount(value: $0, unit: .dollars) }),
            (#"(-?\d+(?:\.\d+)?)\s*\$"#, { Amount(value: $0, unit: .dollars) }),
            (#"(-?\d+(?:\.\d+)?)\s*¢"#, { Amount(value: $0, unit: .cents) }),
            // A rate printed without a unit: "0.053425 per kWh" is dollars, "6.5 per kWh" cents.
            (#"(?:^|[^\d.])(\d*\.\d+)\s*(?:per|/)\s*(?:kwh|kilowatt)"#, { Amount(value: $0 < 1 ? $0 * 100 : $0, unit: .cents) }),
        ]
        for (pattern, make) in rules {
            let regex = try! Regex(pattern).ignoresCase()
            while let m = s.firstMatch(of: regex) {
                let start = s.distance(from: s.startIndex, to: m.range.lowerBound)
                let length = s[m.range].count
                if let v = Double(m.output[1].substring!) {
                    found.append(Located(amount: make(v), start: start, end: start + length))
                }
                s.replaceSubrange(m.range, with: String(repeating: " ", count: length))
            }
        }
        return found.sorted { $0.start < $1.start }
    }
}
