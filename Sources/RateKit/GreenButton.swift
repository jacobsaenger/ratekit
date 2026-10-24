import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads a Green Button (ESPI) usage file, the XML format Smart Meter Texas emails for long
/// date ranges, into daily kWh.
///
/// ESPI layout: an Atom feed whose entries hold a `ReadingType` (unit, power-of-ten
/// multiplier, flow direction), a `MeterReading` linking to its reading type, and
/// `IntervalBlock`s of `IntervalReading`s (`timePeriod/start` in Unix seconds, `value`).
/// Entries are tied together by their `self`, `up` and `related` link URLs. Smart Meter
/// Texas's user guide lists Green Button as an export format; this reader follows the ESPI
/// standard and hasn't yet been checked against a real Smart Meter Texas file.
enum GreenButton {
    struct Reading {
        var totals: [SmartMeterImport.YearMonth: Double]
        var days: [SmartMeterImport.YearMonth: Set<Int>]
        var skippedSurplus: Bool
        var slots: [SmartMeterImport.YearMonth: [Double]]
    }

    static func looksLike(_ text: String) -> Bool {
        let head = text.prefix(4000)
        return head.contains("<feed") || head.contains("IntervalBlock") || head.contains("espi")
    }

    struct ReadingType {
        var multiplier = 0
        var uom: Int?
        var flowDirection: Int?
        var accumulation: Int?

        /// Interval usage drawn from the grid, in watt-hours: flow direction 1 (forward),
        /// unit 72 (Wh), and not a running meter total (accumulation behaviour 1 or 3).
        var isUsage: Bool { uom == 72 && (flowDirection ?? 1) == 1 && accumulation != 1 && accumulation != 3 }
        var isExport: Bool { flowDirection == 19 }
    }
    struct Interval { var start: Double; var value: Double; var duration: Double? }

    /// One parsed Atom entry.
    final class Entry {
        var selfLink = ""
        var upLink = ""
        var related: [String] = []
        var readingType: ReadingType?
        var intervals: [Interval] = []
        var isMeterReading = false
    }

    final class Parser: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var entry: Entry?
        private var path: [String] = []
        private var text = ""
        private var pendingStart: Double?
        private var pendingValue: Double?
        private var pendingDuration: Double?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            path.append(local)
            text = ""
            switch local {
            case "entry": entry = Entry()
            case "link":
                guard let entry, let href = attributes["href"] else { break }
                switch attributes["rel"] {
                case "self": entry.selfLink = href
                case "up": entry.upLink = href
                case "related": entry.related.append(href)
                default: break
                }
            case "ReadingType": entry?.readingType = ReadingType()
            case "MeterReading": entry?.isMeterReading = true
            case "IntervalReading": pendingStart = nil; pendingValue = nil; pendingDuration = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let inReadingType = path.contains("ReadingType")
            let inInterval = path.contains("IntervalReading")
            switch local {
            case "powerOfTenMultiplier" where inReadingType: entry?.readingType?.multiplier = Int(value) ?? 0
            case "uom" where inReadingType: entry?.readingType?.uom = Int(value)
            case "flowDirection" where inReadingType: entry?.readingType?.flowDirection = Int(value)
            case "accumulationBehaviour" where inReadingType: entry?.readingType?.accumulation = Int(value)
            case "start" where inInterval && path.dropLast().last == "timePeriod": pendingStart = Double(value)
            case "duration" where inInterval && path.dropLast().last == "timePeriod": pendingDuration = Double(value)
            case "value" where inInterval: pendingValue = Double(value)
            case "IntervalReading":
                if let start = pendingStart, let v = pendingValue { entry?.intervals.append(Interval(start: start, value: v, duration: pendingDuration)) }
            case "entry":
                if let entry { entries.append(entry) }
                entry = nil
            default: break
            }
            path.removeLast()
            text = ""
        }
    }

    static func read(_ text: String) throws -> Reading {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = Parser()
        parser.delegate = delegate
        guard parser.parse() || !delegate.entries.isEmpty else { throw SmartMeterImport.Failure.notASmartMeterFile }
        let entries = delegate.entries
        let types = entries.filter { $0.readingType != nil }
        guard !types.isEmpty, entries.contains(where: { !$0.intervals.isEmpty }) else {
            throw SmartMeterImport.Failure.notASmartMeterFile
        }

        // Each interval block belongs to the meter reading whose URL it sits under
        // (".../MeterReading/1/IntervalBlock"), and that reading links to its reading type.
        func meterReading(for block: Entry) -> Entry? {
            entries.first { $0.isMeterReading && !$0.selfLink.isEmpty
                && (block.upLink == $0.selfLink + "/IntervalBlock" || block.upLink.hasPrefix($0.selfLink + "/")) }
        }
        func readingType(of reading: Entry?) -> ReadingType? {
            if let reading, let type = types.first(where: { t in reading.related.contains(t.selfLink) }) { return type.readingType }
            // An unlinked file is only safe with a single reading type; with several, a block
            // could be solar export counted as use.
            return types.count == 1 ? types[0].readingType : nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        // Usage per meter reading (one series of readings), as day → kWh.
        var series: [String: [SmartMeterImport.YearMonth: [Int: Double]]] = [:]
        // Hourly or finer readings also fill the time-of-day profile, per series.
        var seriesSlots: [String: [SmartMeterImport.YearMonth: [Double]]] = [:]
        var skippedSurplus = false
        for block in entries where !block.intervals.isEmpty {
            let reading = meterReading(for: block)
            guard let type = readingType(of: reading) else { continue }
            if type.isExport { skippedSurplus = true; continue }
            guard type.isUsage else { continue }
            let key = reading?.selfLink ?? ""
            let toKWh = pow(10, Double(type.multiplier)) / 1000
            for interval in block.intervals {
                let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: interval.start))
                guard let y = c.year, let m = c.month, let d = c.day else { continue }
                let ym = SmartMeterImport.YearMonth(year: y, month: m - 1)
                series[key, default: [:]][ym, default: [:]][d, default: 0] += interval.value * toKWh
                if let duration = interval.duration, duration > 0, duration <= 3600 {
                    let date = Date(timeIntervalSince1970: interval.start)
                    let t = calendar.dateComponents([.hour, .minute, .weekday], from: date)
                    let weekend = t.weekday == 1 || t.weekday == 7
                    let first = ((t.hour ?? 0) * 60 + (t.minute ?? 0)) / 15
                    let count = max(1, Int(duration) / 900)
                    for i in 0..<count where first + i < 96 {
                        seriesSlots[key, default: [:]][ym, default: Array(repeating: 0, count: 192)][first + i + (weekend ? 96 : 0)]
                            += interval.value * toKWh / Double(count)
                    }
                }
            }
        }
        // A file can carry the same usage more than once (15-minute and daily series): use
        // the one series covering the most days rather than adding them up.
        func dayCount(_ s: [SmartMeterImport.YearMonth: [Int: Double]]) -> Int { s.values.reduce(0) { $0 + $1.count } }
        // Ties go to the finer series (one with a time-of-day profile), then by key, so the
        // choice doesn't depend on dictionary order.
        func rank(_ key: String, _ s: [SmartMeterImport.YearMonth: [Int: Double]]) -> (Int, Int, String) {
            (dayCount(s), seriesSlots[key] == nil ? 0 : 1, key)
        }
        guard let (bestKey, best) = series.max(by: { rank($0.key, $0.value) < rank($1.key, $1.value) }) else {
            throw SmartMeterImport.Failure.notASmartMeterFile
        }
        let totals = best.mapValues { $0.values.reduce(0, +) }
        let days = best.mapValues { Set($0.keys) }
        guard !totals.isEmpty else { throw SmartMeterImport.Failure.notASmartMeterFile }
        return Reading(totals: totals, days: days, skippedSurplus: skippedSurplus, slots: seriesSlots[bestKey] ?? [:])
    }
}
