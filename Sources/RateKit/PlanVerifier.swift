import Foundation

/// How far a plan's computed prices may be from Power to Choose's published ones.
/// Published prices are rounded to 0.1¢, so a correct reading is always within this.
/// Never loosen it to pass more plans: a plan that misses is shown as estimated.
public let verificationTolerance = 0.1

public enum PlanStatus: Codable, Equatable, Sendable {
    /// The label's terms reproduce all three published prices.
    case verified
    /// No reading of the label reproduced the published prices.
    case estimated(reason: String)
    /// Time-of-use plans: read separately (`TimeOfUseReader`, `FeedPlan.timeOfUse`) and priced
    /// only for households with a year of time-of-day usage.
    case timeOfUse
}

public struct PlanReading: Equatable, Sendable {
    public var status: PlanStatus
    public var terms: PlanTerms?
    /// The worst miss in ¢/kWh of the closest reading, for the report.
    public var closestMiss: Double?

    public init(status: PlanStatus, terms: PlanTerms? = nil, closestMiss: Double? = nil) {
        self.status = status
        self.terms = terms
        self.closestMiss = closestMiss
    }
}

public enum PlanVerifier {
    public static let checkpoints: [Double] = [500, 1000, 2000]

    /// The largest gap in ¢/kWh between `terms` and the offer's published prices.
    public static func worstMiss(_ terms: PlanTerms, _ offer: PlanOffer) -> Double {
        checkpoints.map { k in
            abs(CostEngine.averagePrice(terms, kWh: k) - (offer.publishedPrice(atKWh: Int(k)) ?? .nan))
        }.max() ?? .infinity
    }

    /// True when `a` and `b` give the same price at all three checkpoints, so the
    /// published prices cannot tell them apart.
    static func indistinguishable(_ a: PlanTerms, _ b: PlanTerms) -> Bool {
        checkpoints.allSatisfy { abs(CostEngine.averagePrice(a, kWh: $0) - CostEngine.averagePrice(b, kWh: $0)) < 1e-9 }
    }

    static func describedByPowerToChoose(_ credit: UsageCredit, _ offer: PlanOffer) -> Bool {
        let text = LabelParser.normalized(offer.feesAndCredits).lowercased()
        guard !text.isEmpty else { return false }
        return Amount.scan(text).contains { a in
            a.unit == .dollars && a.value == credit.amount && LabelParser.credit(amount: a.value, context: text) == credit
        }
    }

    public static func read(_ offer: PlanOffer, labelText: String?) -> PlanReading {
        if offer.timeOfUse { return PlanReading(status: .timeOfUse) }
        guard let labelText else {
            return PlanReading(status: .estimated(reason: "label not readable"))
        }
        if LabelServiceArea.namesOnlyAnother(labelText, tdu: offer.tdu) {
            return PlanReading(status: .estimated(reason: "label is for another service area"))
        }
        let facts = LabelParser.facts(fromLabel: labelText, tdu: offer.tdu, feesAndCredits: offer.feesAndCredits)
        if !facts.unclear.isEmpty {
            return PlanReading(status: .estimated(reason: "credit or fee wording not understood"))
        }
        let options = LabelParser.candidates(from: facts, tdu: offer.tdu)
        if options.isEmpty {
            return PlanReading(status: .estimated(reason: "no energy charge found"))
        }
        // Keep the reading closest to the published prices; the first, most literal
        // reading wins ties.
        var closest: (PlanTerms, Double)? = nil
        for terms in options {
            let miss = worstMiss(terms, offer)
            if closest == nil || miss < closest!.1 - 1e-9 { closest = (terms, miss) }
        }
        if let (terms, miss) = closest, miss <= verificationTolerance {
            // A credit that changes none of the three published prices is not checked by
            // them; accept it only if Power to Choose's own description names it.
            for (i, credit) in terms.credits.enumerated() {
                var without = terms
                without.credits.remove(at: i)
                if indistinguishable(without, terms), !describedByPowerToChoose(credit, offer) {
                    return PlanReading(status: .estimated(reason: "credit not visible in published prices"), closestMiss: miss)
                }
            }
            return PlanReading(status: .verified, terms: terms, closestMiss: miss)
        }
        return PlanReading(
            status: .estimated(reason: "prices do not match"),
            terms: nil,
            closestMiss: closest?.1
        )
    }
}

/// Labels name their service area near the top. A label that names another area and not
/// the plan's own was linked from the wrong offer (Power to Choose, 2026-10-20: two
/// SmartEnergy plans swap their AEP Central and AEP North labels).
enum LabelServiceArea {
    static func names(_ tdu: TDU) -> [String] {
        switch tdu {
        case .oncor, .oncorNTU: ["oncor"]
        case .centerPoint: ["centerpoint", "center point", "cnp"]
        case .aepCentral: ["aep texas central", "aep central", "aep tcc", "aeptcc", "aep-tcc", "central power and light",
                           "central power & light", "cp&l"]
        case .aepNorth: ["aep texas north", "aep north", "aep tnc", "aeptnc", "aep-tnc"]
        case .tnmp: ["texas-new mexico", "texas new mexico", "tnmp"]
        case .lubbock: ["lubbock", "lp&l"]
        case .nueces: ["nueces"]
        }
    }

    static func namesOnlyAnother(_ text: String, tdu: TDU) -> Bool {
        let head = text.lowercased().split(whereSeparator: \.isWhitespace).prefix(120).joined(separator: " ")
        if names(tdu).contains(where: head.contains) { return false }
        return TDU.allCases.contains { other in
            other != tdu && !(Set([other, tdu]) == Set([.oncor, .oncorNTU])) && names(other).contains(where: head.contains)
        }
    }
}
