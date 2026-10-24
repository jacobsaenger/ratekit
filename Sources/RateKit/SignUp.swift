import Foundation

/// Federal business days: weekdays that aren't federal holidays (as observed: a holiday on
/// a Saturday is observed the Friday before, on a Sunday the Monday after).
public enum FederalBusinessDays {
    /// The observed federal holidays in `year`, as (month, day).
    public static func holidays(in year: Int, calendar: Calendar) -> Set<DateComponents> {
        func nth(_ n: Int, _ weekday: Int, of month: Int) -> DateComponents {
            // n = -1 for the last one.
            var c = DateComponents(year: year, month: month, weekday: weekday)
            c.weekdayOrdinal = n
            let d = calendar.date(from: c)!
            return calendar.dateComponents([.year, .month, .day], from: d)
        }
        func observed(_ month: Int, _ day: Int) -> DateComponents {
            let d = calendar.date(from: DateComponents(year: year, month: month, day: day))!
            let shift = [1: 1, 7: -1][calendar.component(.weekday, from: d)] ?? 0
            return calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: shift, to: d)!)
        }
        return [observed(1, 1), nth(3, 2, of: 1), nth(3, 2, of: 2), nth(-1, 2, of: 5), observed(6, 19), observed(7, 4),
                nth(1, 2, of: 9), nth(2, 2, of: 10), observed(11, 11), nth(4, 5, of: 11), observed(12, 25)]
    }

    public static func isBusinessDay(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1 && weekday != 7 else { return false }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        // Next year's New Year's Day is observed on Dec 31 when Jan 1 is a Saturday.
        return !holidays(in: c.year!, calendar: calendar).contains(c) && !holidays(in: c.year! + 1, calendar: calendar).contains(c)
    }

    /// The `n`th federal business day after `date`.
    public static func adding(_ n: Int, to date: Date, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: date)
        var count = 0
        while count < n {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if isBusinessDay(day, calendar: calendar) { count += 1 }
        }
        return day
    }
}

extension ReminderPlanner {
    /// 16 TAC §25.474(j): a new sign-up can be cancelled without a fee within three federal
    /// business days after the terms of service are received. The last day to cancel.
    public static func cancelDeadline(termsReceived: Date, calendar: Calendar = .current) -> Date {
        FederalBusinessDays.adding(3, to: termsReceived, calendar: calendar)
    }
}

/// Does a scanned welcome letter or contract summary match the plan that was chosen?
public struct SignUpConfirmation: Equatable, Sendable {
    public enum Result: Equatable, Sendable { case matches, differs(String), notFound }

    public var planName: Result
    public var price: Result
    public var term: Result

    public var allMatch: Bool { planName == .matches && price == .matches && term == .matches }
    public var anyDiffers: Bool {
        [planName, price, term].contains { if case .differs = $0 { return true } else { return false } }
    }

    /// `price1000` is the plan's price at 1,000 kWh (¢), which its documents show in the
    /// average-price table. `otherPlans` are the provider's other plan names: a letter that
    /// names a longer one ("True Value 12 Plus" for "True Value 12") is for that plan.
    public init(text: String, product: String, price1000: Double, termMonths: Int, otherPlans: [String] = []) {
        let lines = text.lowercased().components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        let flat = lines.joined(separator: " ")

        // The plan's whole name, not part of a longer one ("Digital Choice 3" isn't in
        // "Digital Choice 36").
        func named(_ plan: String) -> Bool {
            let p = NSRegularExpression.escapedPattern(for: plan.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
            return flat.range(of: "(^|[^a-z0-9])" + p + "($|[^a-z0-9])", options: .regularExpression) != nil
        }
        if let longer = otherPlans.filter({ $0.count > product.count && $0.lowercased().contains(product.lowercased()) }).first(where: named) {
            planName = .differs(longer)
        } else {
            planName = named(product) ? .matches : .notFound
        }

        // The price at 1,000 kWh only: "1,000 kWh 11.8¢", or the middle of a 500/1,000/2,000
        // table's price row.
        var at1000: [Double] = []
        for m in flat.matches(of: /1,?000 kwh[^0-9¢]{0,30}?(\d{1,2}\.\d{1,4})\s*(?:¢|cents)/) { if let v = Double(m.1) { at1000.append(v) } }
        if at1000.isEmpty {
            for (i, line) in lines.enumerated() where line.contains("500") && line.contains("2,000") || line.contains("2000") && line.contains("500") {
                for row in lines[i...min(i + 2, lines.count - 1)] {
                    let p = row.matches(of: /(\d{1,2}\.\d{1,4})\s*(?:¢|cents)/).compactMap { Double($0.1) }
                    if p.count == 3 { at1000.append(p[1]); break }
                }
            }
        }
        if at1000.isEmpty { price = .notFound }
        else if at1000.allSatisfy({ abs($0 - price1000) < 0.05 }) { price = .matches }
        else if let other = at1000.first(where: { abs($0 - price1000) >= 0.05 }) { price = .differs(String(format: "%.1f¢", other)) }
        else { price = .notFound }

        // The contract term from its own wording ("Contract Term 12 Months", "12-month
        // contract"), not any number of months the letter mentions.
        var terms: [Int] = []
        for m in flat.matches(of: /(?:term|contract)[^.;]{0,30}?(\d{1,2})[\s-]*months?\b/) { if let v = Int(m.1) { terms.append(v) } }
        for m in flat.matches(of: /(\d{1,2})[\s-]*months?[\s-]*(?:term|contract|plan)\b/) { if let v = Int(m.1) { terms.append(v) } }
        let distinct = Set(terms.filter { (1...60).contains($0) })
        if distinct == [termMonths] { term = .matches }
        else if distinct.count == 1, let other = distinct.first { term = .differs("\(other)") }
        else { term = .notFound }
    }
}
