import Foundation

/// One calendar month's usage read from a bill.
public struct MonthlyUsage: Equatable, Sendable {
    public var year: Int
    /// 1 = January.
    public var month: Int
    public var kWh: Double

    public init(year: Int, month: Int, kWh: Double) {
        self.year = year
        self.month = month
        self.kWh = kWh
    }
}

/// Every month of usage a bill prints, each placed in its calendar month.
///
/// Most Texas bills print one to three months as numbers (research, 2026-10-23): the billing
/// period, and on Reliant, Cirro and similar layouts a small table of recent periods
/// ("Billing Period JUL AUG SEP" over "Electricity Used (kWh) 1,132 1,465 1,000"), or
/// "Current Month / Last Month / Last Year" figures. TXU's 13-month history is a chart whose
/// only numbers are axis ticks, which are never read as usage. A month is returned only
/// when its date is certain; written against published sample bills, not yet real ones.
public enum BillUsageHistory {
    public static func read(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> [MonthlyUsage] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let today = calendar.dateComponents([.year, .month], from: now)
        guard let thisYear = today.year, let thisMonth = today.month else { return [] }
        let period = billingMonth(lines, calendar: calendar)

        var found: [MonthlyUsage] = []
        func add(_ year: Int, _ month: Int, _ kWh: Double) {
            guard (50...10_000).contains(kWh), year * 12 + month <= thisYear * 12 + thisMonth,
                  !found.contains(where: { $0.year == year && $0.month == month }) else { return }
            found.append(MonthlyUsage(year: year, month: month, kWh: kWh))
        }

        // A table of month columns over a usage row. Its newest column is this bill's period:
        // some bills name it by the month most of the period falls in, others by the month
        // the meter was read, one later. Without a period line, the newest column is the
        // latest such month not after today.
        var foundTable = false
        for (i, line) in lines.enumerated() {
            let months = monthTokens(line)
            guard months.count >= 2, let order = consecutiveOrder(months),
                  let values = usageRow(after: i, in: lines, count: months.count) else { continue }
            foundTable = true
            let newestFirst = order == .newestFirst
            let newest = newestFirst ? months[0] : months[months.count - 1]
            var y: Int, m: Int
            if let period, [0, 1].contains((newest - period.month + 12) % 12) {
                (y, m) = (period.year, period.month)
            } else {
                let reference = period ?? (year: thisYear, month: thisMonth)
                (y, m) = (newest <= reference.month ? reference.year : reference.year - 1, newest)
            }
            for kWh in newestFirst ? values : Array(values.reversed()) {
                add(y, m, kWh)
                m -= 1
                if m == 0 { m = 12; y -= 1 }
            }
        }

        // "Current Month 1,767 kWh", "Last Month 2,654 kWh", "Last Year 0 kWh": dated only by
        // the billing period.
        if let period {
            let offsets: [(String, Int)] = [("current month", 0), ("this month", 0), ("last month", -1),
                                            ("previous month", -1), ("last year", -12), ("same month last year", -12)]
            for line in lines {
                let lower = line.lowercased()
                for (label, offset) in offsets where lower.hasPrefix(label) {
                    guard let m = lower.firstMatch(of: /(\d{1,3}(?:,\d{3})+|\d{1,5})\s*kwh/), let kWh = BillTextReader.number(String(m.1)) else { continue }
                    let index = period.year * 12 + (period.month - 1) + offset
                    add(index / 12, index % 12 + 1, kWh)
                }
            }
        }
        // The billing period's own usage, when there's no table: on a table layout the
        // reader's first kWh figure is the table's oldest column.
        if !foundTable, let period, let kWh = BillTextReader.usage(lines) { add(period.year, period.month, kWh) }
        return found.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    // MARK: Billing period

    /// The month most of the billing period falls in: the midpoint of the first two dates on
    /// a line naming the period ("Billing Period 08/21/2026 - 09/22/2026", "Service from …").
    static func billingMonth(_ lines: [String], calendar: Calendar) -> (year: Int, month: Int)? {
        let labels = ["billing period", "service period", "service from", "service dates", "dates of service",
                      "meter read dates", "billing dates", "period of service", "for service"]
        for (i, line) in lines.enumerated() where labels.contains(where: line.lowercased().contains) {
            let text = i + 1 < lines.count ? line + "  " + lines[i + 1] : line
            let dates = allDates(text, calendar: calendar)
            guard dates.count >= 2, dates[1] > dates[0], dates[1].timeIntervalSince(dates[0]) < 40 * 86400 else { continue }
            let middle = dates[0].addingTimeInterval(dates[1].timeIntervalSince(dates[0]) / 2)
            let c = calendar.dateComponents([.year, .month], from: middle)
            if let y = c.year, let m = c.month { return (y, m) }
        }
        return nil
    }

    static func allDates(_ text: String, calendar: Calendar) -> [Date] {
        text.matches(of: /(\d{1,2})\/(\d{1,2})\/(\d{2,4})/).compactMap { m in
            guard let mo = Int(m.1), let d = Int(m.2), var y = Int(m.3) else { return nil }
            if y < 100 { y += 2000 }
            return BillTextReader.make(y, mo, d, calendar)
        }
    }

    // MARK: Month tables

    /// The months a line names as column headings ("JUL AUG SEP", "Sept Oct"), in order. A
    /// line with other words between them (a sentence) has none.
    static func monthTokens(_ line: String) -> [Int] {
        let words = line.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" }).map(String.init)
        var months: [Int] = []
        var run: [Int] = []
        for word in words {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,:"))
            if let m = month(w) {
                run.append(m)
            } else {
                if run.count > months.count { months = run }
                run = []
            }
        }
        return run.count > months.count ? run : months
    }

    static func month(_ word: String) -> Int? {
        let full = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                    "november", "december"]
        if let i = full.firstIndex(of: word) { return i + 1 }
        if word == "sept" { return 9 }
        return word.count == 3 ? BillTextReader.monthNames.firstIndex(of: word).map { $0 + 1 } : nil
    }

    enum Order { case oldestFirst, newestFirst }

    static func consecutiveOrder(_ months: [Int]) -> Order? {
        let steps = zip(months, months.dropFirst()).map { ($1 - $0 + 12) % 12 }
        if steps.allSatisfy({ $0 == 1 }) { return .oldestFirst }
        if steps.allSatisfy({ $0 == 11 }) { return .newestFirst }
        return nil
    }

    /// The usage figures on a "kWh used" row just below the headings, if it has one per month.
    static func usageRow(after header: Int, in lines: [String], count: Int) -> [Double]? {
        let skip = ["daily", "average", "avg", "per day", "temp", "days", "cost", "$"]
        for line in lines[(header + 1)..<min(lines.count, header + 7)] {
            let lower = line.lowercased()
            guard lower.contains("kwh"), ["used", "usage", "consumption", "electricity"].contains(where: lower.contains),
                  !skip.contains(where: lower.contains) else { continue }
            let values = line.matches(of: /(?:^|[^\d.,$])(\d{1,3}(?:,\d{3})+|\d{1,5})(?=$|[^\d.,¢%°º])/)
                .compactMap { BillTextReader.number(String($0.1)) }
            guard values.count == count, !isAxis(values) else { return nil }
            return values
        }
        return nil
    }

    /// Chart ticks: evenly spaced and running to zero ("987 846 705 … 141 0").
    static func isAxis(_ values: [Double]) -> Bool {
        guard values.count >= 3, values.contains(0) else { return false }
        let steps = zip(values, values.dropFirst()).map { $1 - $0 }
        return steps.allSatisfy { abs($0 - steps[0]) <= 1 }
    }
}
