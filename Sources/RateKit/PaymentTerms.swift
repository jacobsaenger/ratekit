import Foundation

/// What a plan needs from you to get its advertised price: automatic payments, paperless
/// billing, and what not doing so costs.
public struct PaymentRequirement: Codable, Equatable, Sendable {
    public var autopay: Bool
    public var paperless: Bool
    /// Dollars added each billing period without them: a fee, or a credit that's lost.
    /// nil when the label states the requirement but not its cost.
    public var feeIfNot: Double?

    public init(autopay: Bool, paperless: Bool, feeIfNot: Double?) {
        self.autopay = autopay
        self.paperless = paperless
        self.feeIfNot = feeIfNot
    }
}

/// Reads autopay and paperless requirements from a label and the plan's special terms.
///
/// The wordings seen on Texas labels (2026-10-22): "Auto Pay & Paperless Credit: $5.00 per
/// month" (a credit already in the advertised prices), "You will incur a fee of $5.00 per
/// billing period if you are not enrolled in Autopay", "Autopay Breakage Fee: $5.00 per
/// billing cycle", "$5.00 Processing Fee for each billing period during which you are not
/// enrolled in Auto-Pay", "Autopay Discount $5.00 per billing cycle", "Autopay required",
/// "This plan requires paperless billing".
public enum PaymentTerms {
    /// The dollar amount closest to the autopay or paperless wording (within 80
    /// characters), so a delivery charge on the same table line isn't taken for it.
    static func nearestAmount(in sentence: String) -> Double? {
        let lower = sentence.lowercased()
        let keys = lower.ranges(of: /auto[- ]?pay|paperless|processing fee|breakage/).map { lower.distance(from: lower.startIndex, to: $0.lowerBound) }
        guard !keys.isEmpty else { return nil }
        var best: (Double, Int)?
        for m in sentence.matches(of: /\$\s*(\d{1,2}(?:\.\d{2})?)/) {
            guard let v = Double(m.1), v > 0, v <= 25 else { continue }
            let at = sentence.distance(from: sentence.startIndex, to: m.range.lowerBound)
            let d = keys.map { abs($0 - at) }.min() ?? .max
            if d <= 80, best == nil || d < best!.1 { best = (v, d) }
        }
        return best?.0
    }

    public static func read(labelText: String?, specialTerms: String = "") -> PaymentRequirement? {
        let text = ((labelText ?? "") + " " + specialTerms)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Sentence ends are a period or semicolon followed by a space, so "$5.00" stays whole.
        let sentences = text.replacingOccurrences(of: "; ", with: ". ").components(separatedBy: ". ")
        var autopay = false, paperless = false
        var fee: Double?
        for raw in sentences {
            let s = raw.lowercased()
            let mentionsAutopay = s.firstMatch(of: /auto[- ]?pay(?:ment)?s?|automatic payments?|recurring payment/) != nil
            let mentionsPaperless = s.contains("paperless") || s.contains("e-bill") || s.contains("ebill")
                || s.contains("electronic bill") || s.contains("electronically") || s.contains("tree free")
                || (s.contains("electronic") && s.contains("delivery"))
            guard mentionsAutopay || mentionsPaperless else { continue }
            // Only sentences that make it a condition of the price: a requirement, a fee
            // without it, or a credit/discount for it.
            let requires = s.contains("required") || s.contains("requires") || s.contains("require ")
                || s.contains("must ") || s.contains("this product requires") || s.contains("is a paperless product")
            // "credit card" is a way to pay, not a credit on the bill.
            let s2 = s.replacingOccurrences(of: "credit card", with: "card")
            let costs = s2.contains("fee") || s2.contains("credit") || s2.contains("discount") || s2.contains("charged")
            guard requires || costs else { continue }
            // "… auto payment … available" offers autopay rather than requiring it.
            if !requires && s.contains("available") { continue }
            if mentionsAutopay { autopay = true }
            if mentionsPaperless && (requires || s2.contains("credit") || s2.contains("discount")) { paperless = true }
            if costs, fee == nil, let v = nearestAmount(in: raw) { fee = v }
        }
        guard autopay || paperless else { return nil }
        return PaymentRequirement(autopay: autopay, paperless: paperless, feeIfNot: fee)
    }
}

/// Whether a plan's sign-up link works, from the feed job's daily check.
public struct LinkCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Opens a page on the provider's site (the plan or its sign-up flow).
        case ok
        /// Lands on the provider's home page, so the plan has to be found by hand.
        case homepage
        /// Returned "not found" or a server error today.
        case broken
    }
    public var status: Status

    public init(status: Status) { self.status = status }

    /// Classifies a response: `final` is where redirects ended. 401, 403 and 429 (sites that
    /// block automated checks) and network errors aren't judged: nil. A link that was a bare
    /// address to begin with isn't judged either: a sign-up site's front page can be the
    /// sign-up form ("signup.example.com/").
    public static func classify(original: URL, final: URL?, statusCode: Int?) -> LinkCheck? {
        guard let code = statusCode else { return nil }
        if [401, 403, 429].contains(code) { return nil }
        if code == 404 || code == 410 || code >= 500 { return LinkCheck(status: .broken) }
        guard (200..<400).contains(code) else { return nil }
        func bare(_ u: URL) -> Bool {
            let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return (path.isEmpty || ["en", "en-us", "home", "index.html"].contains(path.lowercased())) && (u.query ?? "").isEmpty
        }
        if bare(original) { return nil }
        return LinkCheck(status: bare(final ?? original) ? .homepage : .ok)
    }
}
