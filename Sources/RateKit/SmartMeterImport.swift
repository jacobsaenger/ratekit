import Foundation

/// Reads a Smart Meter Texas usage export (CSV) into monthly kWh.
///
/// The 15-minute "Energy Data" file's columns are known: ESIID, USAGE_DATE, REVISION_DATE,
/// USAGE_START_TIME, USAGE_END_TIME, USAGE_KWH, ESTIMATED_ACTUAL,
/// CONSUMPTION_SURPLUSGENERATION, with dates as MM/DD/YYYY. The daily-read and monthly
/// billing files' headers aren't documented anywhere we could check, so columns are found
/// by name: a date column, then a kWh column (or start and end meter readings).
public enum SmartMeterImport {
    public struct Result: Equatable, Sendable {
        /// kWh by month index (0 = January) for up to the last 12 complete months.
        public var monthlyKWh: [Int: Double]
        /// The months used, oldest first, as (year, month index).
        public var months: [YearMonth]
        /// True when solar export rows were left out.
        public var skippedSurplus: Bool
        /// When in the day the household uses power, from 15-minute or hourly data; nil for
        /// daily and monthly files.
        public var profile: UsageProfile?
    }

    public struct YearMonth: Hashable, Comparable, Sendable {
        public var year: Int
        public var month: Int
        public static func < (a: YearMonth, b: YearMonth) -> Bool { (a.year, a.month) < (b.year, b.month) }

        func adding(months: Int) -> YearMonth {
            let index = year * 12 + month + months
            return YearMonth(year: index / 12, month: index % 12)
        }
    }

    public enum Failure: Error, Equatable {
        /// No row with a date column and a kWh (or meter reading) column.
        case notASmartMeterFile
        /// The file has the columns but no complete month of usage.
        case noCompleteMonths
    }

    /// A month counts when daily data covers 90% of its days; a billing-period file's rows
    /// each count as the month holding the period's middle day.
    public static let completeShare = 0.9
    /// More than any home uses in a month.
    public static let maximumMonthKWh = 20_000.0

    public static func read(_ text: String) throws -> Result {
        if GreenButton.looksLike(text) {
            let reading = try GreenButton.read(text)
            return try summarize(totals: reading.totals, days: reading.days, billingPeriods: false,
                                 skippedSurplus: reading.skippedSurplus, slots: reading.slots)
        }
        let rows = CSV.rows(text)
        guard let headerIndex = rows.firstIndex(where: { columns(in: $0) != nil }),
              let cols = columns(in: rows[headerIndex]) else { throw Failure.notASmartMeterFile }

        // An interval SMT revised appears again with a newer revision date: the later copy
        // replaces it. Two rows with the same date, start time and revision are the repeated
        // hour when daylight saving ends: both count.
        var byKey: [String: (day: Day, start: Day?, revision: String, kWh: Double)] = [:]
        var order: [String] = []
        var skippedSurplus = false
        for row in rows[(headerIndex + 1)...] {
            func cell(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                return clean(row[i])
            }
            guard let dateText = cell(cols.date), let day = Day(dateText) else { continue }
            if let kind = cell(cols.surplus), kind.lowercased().contains("surplus") {
                skippedSurplus = true
                continue
            }
            let kWh: Double
            if let k = cell(cols.kWh).flatMap(number) {
                kWh = k
            } else if let s = cell(cols.startReading).flatMap(number), let e = cell(cols.endReading).flatMap(number), e >= s {
                kWh = e - s
            } else {
                continue   // blank usage, e.g. the hour skipped when daylight saving starts
            }
            let key = dateText + "|" + (cell(cols.startTime) ?? "")
            let revision = cell(cols.revision) ?? ""
            if let existing = byKey[key], existing.revision == revision, cols.startTime != nil {
                byKey[key]?.kWh += kWh
                continue
            }
            if byKey[key] == nil { order.append(key) }
            byKey[key] = (day, cell(cols.startDate).flatMap(Day.init), revision, kWh)
        }

        var totals: [YearMonth: Double] = [:]
        var days: [YearMonth: Set<Int>] = [:]
        var slots: [YearMonth: [Double]] = [:]
        for key in order {
            guard let entry = byKey[key] else { continue }
            // Interval rows also fill the time-of-day profile ("13:45" → slot 55).
            // 24-hour times only: "1:15 PM" would put afternoons in the morning, so a file with
            // am/pm times gets no profile.
            if cols.startTime != nil, let time = key.split(separator: "|").last, !time.lowercased().contains("m"),
               let m = time.firstMatch(of: /^(\d{1,2}):(\d{2})/), let h = Int(m.1), let mm = Int(m.2), h < 24, mm < 60 {
                let slot = (h * 60 + mm) / 15 + (entry.day.isWeekend ? 96 : 0)
                slots[entry.day.yearMonth, default: Array(repeating: 0, count: 192)][slot] += entry.kWh
            }
            if cols.billingPeriods {
                // A billing period belongs to the month holding its middle day; a later
                // period for the same month replaces an earlier one rather than adding to it.
                totals[(entry.start.map { Day.middle($0, entry.day) } ?? entry.day).yearMonth] = entry.kWh
            } else {
                totals[entry.day.yearMonth, default: 0] += entry.kWh
                days[entry.day.yearMonth, default: []].insert(entry.day.day)
            }
        }
        return try summarize(totals: totals, days: days, billingPeriods: cols.billingPeriods, skippedSurplus: skippedSurplus,
                             slots: slots)
    }

    /// Monthly totals to the result: daily and interval data must cover 90% of a month's days
    /// for it to count, and a month with a few days missing is scaled up to the whole month.
    static func summarize(totals: [YearMonth: Double], days: [YearMonth: Set<Int>], billingPeriods: Bool,
                          skippedSurplus: Bool, slots: [YearMonth: [Double]] = [:]) throws -> Result {
        var complete: [YearMonth: Double] = [:]
        for (ym, total) in totals {
            if billingPeriods {
                complete[ym] = total
            } else {
                let covered = Double(days[ym]?.count ?? 0), all = Double(Day.daysIn(ym))
                if covered >= completeShare * all { complete[ym] = total * all / covered }
            }
        }
        // No home uses this much in a month: the file holds meter readings or the same
        // usage twice, so it isn't read rather than ranked on.
        guard complete.values.allSatisfy({ $0 <= maximumMonthKWh }) else { throw Failure.notASmartMeterFile }
        // The 12 calendar months ending with the latest complete one; gaps stay estimated.
        guard let latest = complete.keys.max() else { throw Failure.noCompleteMonths }
        let earliest = latest.adding(months: -11)
        let recent = complete.keys.filter { $0 >= earliest }.sorted()
        var monthly: [Int: Double] = [:]
        for ym in recent { monthly[ym.month] = (complete[ym] ?? 0).rounded() }
        // The time-of-day profile for the same months, when the file has intervals.
        var profile: UsageProfile?
        if recent.contains(where: { slots[$0] != nil }) {
            var byMonth = Array(repeating: Array(repeating: 0.0, count: 192), count: 12)
            for ym in recent { if let s = slots[ym] { byMonth[ym.month] = s } }
            profile = UsageProfile(slots: byMonth)
        }
        return Result(monthlyKWh: monthly, months: recent, skippedSurplus: skippedSurplus, profile: profile)
    }

    struct Columns {
        var date: Int
        var kWh: Int?
        var startReading: Int?
        var endReading: Int?
        var startTime: Int?
        var surplus: Int?
        var revision: Int?
        var startDate: Int?
        /// Each row is a billing period with start and end dates; `date` is the end date.
        var billingPeriods: Bool
    }

    static func columns(in row: [String]) -> Columns? {
        let names = row.map { clean($0).uppercased().replacingOccurrences(of: " ", with: "_") }
        func find(_ test: (String) -> Bool) -> Int? { names.firstIndex(where: test) }
        let date = find { $0 == "USAGE_DATE" } ?? find { $0.contains("DATE") && $0.contains("END") }
            ?? find { $0.contains("DATE") && !$0.contains("REVISION") && !$0.contains("START") }
            ?? find { $0.contains("DATE") && !$0.contains("REVISION") }
        guard let date else { return nil }
        let kWh = find { $0.contains("KWH") }
        let start = find { $0.contains("START") && $0.contains("READ") }
        let end = find { $0.contains("END") && $0.contains("READ") }
        guard kWh != nil || (start != nil && end != nil) else { return nil }
        let startDate = find { $0.contains("DATE") && $0.contains("START") }
        return Columns(date: date, kWh: kWh, startReading: start, endReading: end,
                       startTime: find { $0.contains("START") && $0.contains("TIME") },
                       surplus: find { $0.contains("SURPLUS") },
                       revision: find { $0.contains("REVISION") },
                       startDate: startDate,
                       billingPeriods: startDate != nil && names[date].contains("END"))
    }

    /// Strips quotes, spaces and the apostrophe SMT puts before ESI IDs.
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    struct Day {
        var year: Int
        var month: Int
        var day: Int

        /// "10/22/2026" (with or without a time after it) or "2026-10-22".
        init?(_ text: String) {
            let datePart = text.split(separator: " ").first.map(String.init) ?? text
            let parts: [Int]
            if datePart.contains("/") {
                let p = datePart.split(separator: "/").compactMap { Int($0) }
                guard p.count == 3 else { return nil }
                parts = [p[2], p[0], p[1]]
            } else {
                parts = datePart.split(separator: "-").compactMap { Int($0) }
            }
            guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]), parts[0] > 1900 else { return nil }
            (year, month, day) = (parts[0], parts[1], parts[2])
        }

        var yearMonth: YearMonth { YearMonth(year: year, month: month - 1) }

        var isWeekend: Bool {
            let calendar = Calendar(identifier: .gregorian)
            guard let d = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
            let weekday = calendar.component(.weekday, from: d)
            return weekday == 1 || weekday == 7
        }

        /// The day halfway between two days.
        static func middle(_ a: Day, _ b: Day) -> Day {
            let calendar = Calendar(identifier: .gregorian)
            guard let x = calendar.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
                  let y = calendar.date(from: DateComponents(year: b.year, month: b.month, day: b.day)) else { return b }
            let mid = calendar.dateComponents([.year, .month, .day], from: x.addingTimeInterval(y.timeIntervalSince(x) / 2))
            return Day(year: mid.year ?? b.year, month: mid.month ?? b.month, day: mid.day ?? b.day)
        }

        init(year: Int, month: Int, day: Int) {
            (self.year, self.month, self.day) = (year, month, day)
        }

        static func daysIn(_ ym: YearMonth) -> Int {
            var c = DateComponents()
            c.year = ym.year
            c.month = ym.month + 1
            let calendar = Calendar(identifier: .gregorian)
            return calendar.date(from: c).flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 30
        }
    }
}
