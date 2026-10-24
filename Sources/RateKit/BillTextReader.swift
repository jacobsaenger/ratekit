import Foundation

/// What a bill's text says, as far as it can be read. Every field is optional: bill layouts
/// differ by provider, so the app fills in what was found and the user checks it.
public struct BillFacts: Equatable, Sendable {
    public var kWh: Double?
    /// Electricity charges before taxes, dollars.
    public var charges: Double?
    /// The bill's total including taxes, used only when no pre-tax figure is found.
    public var totalDue: Double?
    public var contractEnd: Date?
    /// Energy charge, ¢/kWh.
    public var energyRate: Double?
    /// Base or monthly service charge, dollars.
    public var baseCharge: Double?
    public var provider: String?
    /// The meter's ESI ID (17 or 22 digits), which sign-up forms ask for.
    public var esiID: String?
    /// The service address as printed: street, then city, state and ZIP.
    public var serviceAddress: String?

    public var isEmpty: Bool {
        kWh == nil && charges == nil && totalDue == nil && contractEnd == nil && energyRate == nil && baseCharge == nil
            && provider == nil && esiID == nil && serviceAddress == nil
    }
}

/// Reads the facts from a bill's text (recognized from a photo or taken from a PDF).
///
/// The rules work line by line on labels Texas bills commonly use ("kWh used", "Total
/// electric charges", "Contract expiration date", "Energy charge", "Base charge"). They have
/// been written against typical layouts, not yet against a set of real bills.
public enum BillTextReader {
    /// Base charges above this aren't a plan's monthly charge.
    static let maximumBaseCharge = 40.0
    /// An energy charge outside this range (¢/kWh) is a misread or a delivery line.
    static let energyRateRange = 3.0...40.0

    public static func read(_ text: String, providers: [String] = [], calendar: Calendar = .current) -> BillFacts {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var facts = BillFacts()
        facts.kWh = usage(lines)
        let pastBalance = ["previous", "past", "prior", "balance", "last bill"]
        facts.charges = dollars(after: ["total electric charges", "total electricity charges", "current electric charges",
                                        "current electricity charges", "electric charges", "electricity charges"],
                                in: lines, avoiding: ["tax"] + pastBalance)
        facts.totalDue = dollars(after: ["total amount due", "total due", "total current charges", "current charges"],
                                 in: lines, avoiding: pastBalance)
        // Pre-tax charges can't be more than the total with taxes.
        if let charges = facts.charges, let total = facts.totalDue, charges > total { facts.charges = nil }
        facts.contractEnd = contractEnd(lines, calendar: calendar)
        facts.energyRate = energyRate(lines)
        facts.baseCharge = dollars(after: ["base charge", "monthly service charge", "base fee"], in: lines,
                                   avoiding: ["delivery", "tdu", "tdsp", "total"])
        if let base = facts.baseCharge, base > maximumBaseCharge { facts.baseCharge = nil }
        facts.provider = provider(in: text, from: providers)
        facts.esiID = esiID(lines)
        facts.serviceAddress = serviceAddress(lines)
        return facts
    }

    // MARK: ESI ID and service address

    /// "ESI ID: 1008901023800000000000" (spaces allowed): 17 or 22 digits after an ESI label.
    static func esiID(_ lines: [String]) -> String? {
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard lower.contains("esi") || lower.contains("electric service identifier") else { continue }
            for candidate in [line, i + 1 < lines.count ? lines[i + 1] : ""] {
                let compact = candidate.replacingOccurrences(of: " ", with: "")
                if let m = compact.firstMatch(of: /(?:^|\D)(\d{22}|\d{17})(?!\d)/) { return String(m.1) }
            }
        }
        return nil
    }

    /// The street line after "Service Address" (on the same line or the next), plus the
    /// city line when it ends in a Texas ZIP.
    static func serviceAddress(_ lines: [String]) -> String? {
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard let label = lower.range(of: "service address") ?? lower.range(of: "service location") else { continue }
            let rest = String(line[line.index(line.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: label.upperBound))...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            var parts: [String] = []
            var next = i + 1
            if rest.first?.isNumber == true { parts.append(rest) }
            else if next < lines.count, lines[next].first?.isNumber == true { parts.append(lines[next]); next += 1 }
            guard !parts.isEmpty else { continue }
            if !parts[0].contains(where: { $0 == "," }), next < lines.count,
               lines[next].firstMatch(of: /\b(TX|Texas)\b.*\b7[5-9]\d{3}\b/.ignoresCase()) != nil {
                parts.append(lines[next])
            }
            return parts.joined(separator: ", ")
        }
        return nil
    }

    // MARK: kWh used

    static func usage(_ lines: [String]) -> Double? {
        // Lines naming the month's usage outright come first; a heading on the line above
        // ("Electricity Usage") only counts for lines that aren't meter reads or averages.
        let explicit = ["kwh used", "kwh usage", "usage (kwh)", "total kwh", "kwh billed", "billed kwh", "energy used", "used"]
        let keywords = explicit + ["usage", "consumption"]
        let notUsage = ["read", "previous", "average", "avg", "per kwh", "/kwh", "¢", "last year", "year ago"]
        var candidates: [Double] = []
        let ordered = lines.indices.sorted { a, b in
            let ea = explicit.contains(where: lines[a].lowercased().contains), eb = explicit.contains(where: lines[b].lowercased().contains)
            return ea != eb ? ea : a < b
        }
        for i in ordered {
            let line = lines[i]
            let lower = line.lowercased()
            guard lower.contains("kwh"), !notUsage.contains(where: lower.contains) else { continue }
            let window = ([i > 0 ? lines[i - 1].lowercased() : ""] + [lower]).joined(separator: " ")
            guard keywords.contains(where: window.contains) else { continue }
            // "1,234 kWh", "kWh used: 1,234", "Usage (kWh) 1234"
            for match in line.matches(of: /(\d{1,3}(?:,\d{3})+|\d{2,5})(?:\.\d+)?\s*kwh/.ignoresCase()) {
                if let v = number(String(match.1)) { candidates.append(v) }
            }
            if candidates.isEmpty, let m = line.firstMatch(of: /kwh[^0-9$]*(\d{1,3}(?:,\d{3})+|\d{2,5})(?!\d)/.ignoresCase()), let v = number(String(m.1)) {
                candidates.append(v)
            }
        }
        // A month's usage, not a meter reading or a yearly total.
        return candidates.first { (50...10_000).contains($0) }
    }

    // MARK: Dollar amounts

    /// The first dollar amount on the line with one of `labels` (or the line after it).
    static func dollars(after labels: [String], in lines: [String], avoiding: [String] = []) -> Double? {
        for label in labels {
            for (i, line) in lines.enumerated() {
                let lower = line.lowercased()
                guard lower.contains(label), !avoiding.contains(where: lower.contains) else { continue }
                let rest = String(lower[lower.range(of: label)!.upperBound...])
                if let v = money(rest) { return v }
                if i + 1 < lines.count, let v = money(lines[i + 1]), lines[i + 1].count < 20 { return v }
            }
        }
        return nil
    }

    static func money(_ text: String) -> Double? {
        guard let m = text.firstMatch(of: /\$\s*(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})(?!\d)/) ?? text.firstMatch(of: /(?:^|[^\d.,])(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})(?!\d)/) else { return nil }
        return number("\(m.1).\(m.2)")
    }

    // MARK: Energy rate

    static func energyRate(_ lines: [String]) -> Double? {
        for line in lines {
            let lower = line.lowercased()
            guard lower.contains("energy charge") || lower.contains("energy rate"),
                  !["delivery", "tdu", "tdsp", "transmission"].contains(where: lower.contains) else { continue }
            var rate: Double?
            if let m = lower.firstMatch(of: /(\d{1,2}(?:\.\d+)?)\s*(?:¢|cents)/), let v = Double(m.1) { rate = v }
            else if let m = lower.firstMatch(of: /\$\s*0?\.(\d{2,6})/), let v = Double("0.\(m.1)") { rate = v * 100 }
            else if let m = lower.firstMatch(of: /@\s*(0?\.\d{2,6})/), let v = Double(m.1) { rate = v * 100 }
            if let rate, energyRateRange.contains(rate) { return rate }
        }
        return nil
    }

    // MARK: Contract end

    static func contractEnd(_ lines: [String], calendar: Calendar) -> Date? {
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard lower.contains("contract") || lower.contains("agreement"),
                  let keyword = lower.range(of: "expir") ?? lower.range(of: "end") else { continue }
            // Only the text after "end"/"expires": a start date earlier on the line isn't it.
            let after = String(line[line.index(line.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: keyword.upperBound))...])
            if let d = date(after, calendar: calendar) { return d }
            // The value on the next line, unless that line is its own labelled date.
            if after.trimmingCharacters(in: .whitespaces).count < 8, i + 1 < lines.count {
                let next = lines[i + 1].lowercased()
                let labels = ["due", "service", "period", "read", "start", "bill", "statement", "issue", "print", "from", "through"]
                if !labels.contains(where: next.contains), let d = date(lines[i + 1], calendar: calendar) { return d }
            }
        }
        return nil
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "03/31/2027", "3/31/27", "March 31, 2027", "Mar 31 2027".
    static func date(_ text: String, calendar: Calendar) -> Date? {
        if let m = text.firstMatch(of: /(\d{1,2})\/(\d{1,2})\/(\d{2,4})/), let mo = Int(m.1), let d = Int(m.2), var y = Int(m.3) {
            if y < 100 { y += 2000 }
            return make(y, mo, d, calendar)
        }
        if let m = text.lowercased().firstMatch(of: /(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})/),
           let mo = monthNames.firstIndex(of: String(m.1)), let d = Int(m.2), let y = Int(m.3) {
            return make(y, mo + 1, d, calendar)
        }
        return nil
    }

    static func make(_ y: Int, _ m: Int, _ d: Int, _ calendar: Calendar) -> Date? {
        guard (2000...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    // MARK: Provider

    /// The longest provider name from the plan list that appears in the text.
    static func provider(in text: String, from providers: [String]) -> String? {
        let lower = text.lowercased()
        return providers.filter { $0.count >= 3 && lower.contains($0.lowercased()) }.max { $0.count < $1.count }
    }

    static func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: "")) }
}
