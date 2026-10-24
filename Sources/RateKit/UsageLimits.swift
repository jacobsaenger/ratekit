import Foundation

/// The usage limits a credit or fee sentence states, read as comparisons.
///
/// Every phrasing is first rewritten to a symbol (">= 1000 kwh", "<= 2000 kwh", …) and
/// the symbols are then read. Inclusive bounds stay as written; strict ones move by one
/// kWh, which is exact because meters bill whole kWh. A sentence with two different
/// lower (or upper) limits, limits that cross, or a kWh figure with no comparison is
/// unclear and yields nil, so the plan is shown as estimated instead of guessed.
struct UsageLimits: Equatable {
    var min: Double?
    var max: Double?

    init(min: Double?, max: Double?) {
        self.min = min
        self.max = max
    }

    /// nil when the limits are unclear. A sentence with no kWh figure has no limits.
    init?(_ sentence: String) {
        let s = UsageLimits.symbolic(sentence)
        guard s.contains("kwh") else { self.init(min: nil, max: nil); return }

        let figures = s.matches(of: /(\d+(?:\.\d+)?)\s*kwh/).count
        if let (a, b) = LabelParser.range(in: s) {
            // A range must be the sentence's only limit: its two figures (one may lack
            // "kWh", as in "1100-1900 kWh") are all the kWh figures there are.
            guard figures <= 2, s.matches(of: /(>=|<=|>|<)\s*\d/).isEmpty else { return nil }
            self.init(min: a, max: b)
            return
        }

        var lows: Set<Double> = []
        var highs: Set<Double> = []
        let comparison = /(>=|<=|>|<)\s*(\d+(?:\.\d+)?)\s*kwh/
        for m in s.matches(of: comparison) {
            guard let n = Double(m.2) else { continue }
            switch m.1 {
            case ">=": lows.insert(n)
            case ">": lows.insert(n + 1)
            case "<=": highs.insert(n)
            case "<": highs.insert(n - 1)
            default: break
            }
        }
        // Every kWh figure must belong to a comparison.
        let compared = s.matches(of: comparison).count
        guard figures == compared, lows.count <= 1, highs.count <= 1, !(lows.isEmpty && highs.isEmpty) else { return nil }
        let lo = lows.first, hi = highs.first
        if let lo, let hi, lo > hi { return nil }
        self.init(min: lo, max: hi)
    }

    /// Rewrites comparison phrases as symbols placed before the number.
    static func symbolic(_ sentence: String) -> String {
        var s = sentence.lowercased()
        s = s.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "≥", with: ">=").replacingOccurrences(of: "≤", with: "<=")
        // Number-first forms: "1000 kWh or more", "1001+ kWh", "499 kWh or less".
        let after: [(String, String)] = [
            (#"(\d+(?:\.\d+)?)\s*\+\s*kwh"#, ">= $1 kwh"),
            (#"(\d+(?:\.\d+)?)\s*kwh\s*(?:or more|or greater|or higher|and above|and over|and up|or above|or over)\b"#, ">= $1 kwh"),
            (#"(\d+(?:\.\d+)?)\s*kwh\s*(?:or less|or fewer|and below|and under|or below|or under)\b"#, "<= $1 kwh"),
            // "from 1000 kWh" alone is a lower limit; "from 1000 kWh to 2000 kWh" stays a range.
            (#"\bfrom\s+(\d+(?:\.\d+)?)\s*kwh(?!\s*(?:-|to|through)\s*\d)"#, ">= $1 kwh"),
        ]
        for (pattern, replacement) in after {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // Word-first forms, longest first so "less than or equal to" is not read as "less than".
        let before: [(String, String)] = [
            ("greater than or equal to", ">="), ("equal to or greater than", ">="), ("equal or greater than", ">="),
            ("greater than or equal", ">="), ("equal to or more than", ">="), ("more than or equal to", ">="),
            ("no less than", ">="), ("not less than", ">="), ("at least", ">="), ("minimum of", ">="),
            ("less than or equal to", "<="), ("equal to or less than", "<="), ("equal or less than", "<="),
            ("less than or equal", "<="), ("not more than", "<="), ("no more than", "<="), ("not to exceed", "<="),
            ("not exceeding", "<="), ("up to", "<="), ("at most", "<="), ("maximum of", "<="),
            ("greater than", ">"), ("more than", ">"), ("in excess of", ">"), ("exceeding", ">"), ("exceeds", ">"),
            ("exceed", ">"), ("above", ">"), ("over", ">"),
            ("less than", "<"), ("fewer than", "<"), ("below", "<"), ("under", "<"),
        ]
        for (phrase, symbol) in before {
            s = s.replacingOccurrences(of: #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#,
                                       with: " \(symbol) ", options: .regularExpression)
        }
        // "is >= 1000 kwh" → ">= 1000 kwh"; join "> =" left by spacing.
        s = s.replacingOccurrences(of: #">\s*="#, with: ">=", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<\s*="#, with: "<=", options: .regularExpression)
        // A comparison followed by filler before the number: ">= to 1000 kwh", "< than 500 kwh".
        s = s.replacingOccurrences(of: #"(>=|<=|>|<)\s*(?:to|than|of)\s+(?=\d)"#, with: "$1 ", options: .regularExpression)
        return s
    }
}
