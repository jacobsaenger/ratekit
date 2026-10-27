import Foundation

/// A provider's informal complaints to the PUCT over six months, by type, from Power to
/// Choose's complaint history page (`/en-us/Content/Scores/<plan id>?c=<company id>`, the
/// "History" link beside each listing). These are raw counts: a large provider gets more
/// than a small one, so they say what people complain about, not who is worse. The complaint
/// rating (`PlanOffer.complaintScore`) is the per-customer comparison.
public struct ComplaintHistory: Codable, Equatable, Sendable {
    /// The months covered, as the page prints them ("Apr 2026 to Oct 2026").
    public var period: String
    /// Complaints received in the period by the PUCT's type ("Billing", "Slamming", …).
    public var counts: [String: Int]

    public init(period: String, counts: [String: Int]) {
        self.period = period
        self.counts = counts
    }

    public var total: Int { counts.values.reduce(0, +) }

    /// The types with complaints, most first.
    public var types: [(name: String, count: Int)] {
        counts.filter { $0.value > 0 }.map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// Reads the page's `var chartData = [...]` (one entry per type with `StatName` and
    /// `TotalReceived`) and its "Period:" line. Nil if either is missing.
    public static func parse(html: String) -> ComplaintHistory? {
        guard let start = html.range(of: "var chartData = "),
              let end = html[start.upperBound...].firstMatch(of: /\]\s*;/),
              let data = String(html[start.upperBound...end.range.lowerBound]).data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty,
              let period = html.firstMatch(of: /Period:\s*([^<]+?)\s*</)?.1
        else { return nil }
        var counts: [String: Int] = [:]
        for row in rows {
            guard let name = row["StatName"] as? String, let total = row["TotalReceived"] as? Int else { return nil }
            counts[name] = total
        }
        return ComplaintHistory(period: String(period), counts: counts)
    }
}
