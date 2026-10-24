import Foundation

/// One day's lowest price in an area, ¢/kWh.
public struct PricePoint: Codable, Equatable, Sendable {
    /// Central-time calendar date, "2026-10-22".
    public var date: String
    public var cents: Double

    public init(date: String, cents: Double) {
        self.date = date
        self.cents = cents
    }
}

/// The daily lowest price per area, kept by the feed job and carried in the feed.
///
/// The price is the cheapest verified plan of 12 months or longer for a typical home
/// (a 1,500–1,999 sq ft house, priced over its whole year), not the advertised price at
/// 1,000 kWh, which bill-credit plans are built to win.
public enum PriceHistory {
    public static let referenceHome = UsageEstimate.Home.house1500to1999
    public static let keepDays = 400

    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Today's point for each area (keyed by `TDU` raw value) with a ranked plan.
    public static func points(for feed: Feed, on date: Date) -> [String: PricePoint] {
        let usage = UsageEstimate.estimate(for: referenceHome)
        var points: [String: PricePoint] = [:]
        for tdu in TDU.allCases {
            guard let best = PlanRanking(feed: feed, tdu: tdu, usage: usage).ranked.first else { continue }
            points[tdu.rawValue] = PricePoint(date: day(date), cents: (best.averagePrice * 100).rounded() / 100)
        }
        return points
    }

    /// `history` with today's points added (replacing any for the same day), sorted by
    /// date, keeping the last `keepDays` days.
    public static func merged(_ history: [String: [PricePoint]], adding today: [String: PricePoint], now: Date) -> [String: [PricePoint]] {
        let cutoff = day(now.addingTimeInterval(-Double(keepDays) * 86400))
        var result: [String: [PricePoint]] = [:]
        for key in Set(history.keys).union(today.keys) {
            var points = (history[key] ?? []).filter { $0.date != today[key]?.date && $0.date >= cutoff }
            if let point = today[key] { points.append(point) }
            result[key] = points.sorted { $0.date < $1.date }
        }
        return result
    }
}

/// What the history says about one area, for the app.
public struct PriceTrend: Equatable, Sendable {
    public var points: [PricePoint]
    public var latest: PricePoint
    /// The point closest to 30 days before the latest, if the history reaches back 3 weeks.
    public var monthAgo: PricePoint?
    public var low: PricePoint
    public var high: PricePoint

    /// Change since `monthAgo`, percent.
    public var monthChange: Double? {
        monthAgo.map { ($0.cents == 0) ? 0 : (latest.cents - $0.cents) / $0.cents * 100 }
    }

    /// nil with fewer than two days of history.
    public init?(points: [PricePoint]) {
        let sorted = points.sorted { $0.date < $1.date }
        guard sorted.count >= 2, let latest = sorted.last,
              let low = sorted.min(by: { $0.cents < $1.cents }),
              let high = sorted.max(by: { $0.cents < $1.cents }) else { return nil }
        self.points = sorted
        self.latest = latest
        self.low = low
        self.high = high
        let target = PriceTrend.date(latest.date).map { $0.addingTimeInterval(-30 * 86400) }
        let earlier = sorted.dropLast().compactMap { p in PriceTrend.date(p.date).map { (p, $0) } }
        if let target, let first = earlier.first, first.1 <= target.addingTimeInterval(9 * 86400) {
            monthAgo = earlier.min { abs($0.1.timeIntervalSince(target)) < abs($1.1.timeIntervalSince(target)) }?.0
        }
    }

    /// The start of a "2026-10-22" day in Central time.
    public static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
