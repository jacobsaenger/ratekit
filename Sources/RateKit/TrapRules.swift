import Foundation

/// A plain-English warning about a plan feature that can make it cost more than its
/// headline price suggests.
public struct TrapWarning: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case billCreditCliff, minimumUsageFee, teaserTerm, variableRate, prepaid, highCancelFee, paymentRequirement
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    /// For a bill-credit cliff: the household's months (0 = first month given) that miss the credit.
    public var monthsMissingCredit: [Int]
    /// The numbers in `detail`, in order, so the app can word the warning in the user's
    /// language: cliff [¢ at 1,000, ¢ at 500, ¢ at 2,000]; minimum-usage fee [$, kWh];
    /// short contract [months]; cancellation fee [$]; payment requirement [$ a bill without
    /// it, or 0 if not stated, 1 if autopay, 1 if paperless].
    public var values: [Double] = []
    /// For a cancellation fee: charged per month left rather than once.
    public var perMonth = false

    public var id: Kind { kind }
}

public enum TrapRules {
    /// Above this many dollars, a flat cancellation fee is flagged.
    public static let highCancelFee = 150.0

    public static func warnings(for offer: PlanOffer, terms: PlanTerms?, monthlyKWh: [Double] = [],
                                payment: PaymentRequirement? = nil) -> [TrapWarning] {
        var out: [TrapWarning] = []
        if let payment {
            let what = payment.autopay && payment.paperless ? "autopay and paperless billing"
                : payment.autopay ? "autopay" : "paperless billing"
            let detail = payment.feeIfNot.map { String(format: "The advertised price assumes %@; without it you pay $%.2f more each bill.", what, $0) }
                ?? "The plan requires \(what)."
            out.append(TrapWarning(kind: .paymentRequirement, title: "Needs \(what)", detail: detail, monthsMissingCredit: [],
                                   values: [payment.feeIfNot ?? 0, payment.autopay ? 1 : 0, payment.paperless ? 1 : 0]))
        }

        if offer.price500 >= 1.5 * offer.price1000 || offer.price2000 >= 1.5 * offer.price1000 {
            let missing = monthsMissingCredit(terms, monthlyKWh)
            let detail = String(
                format: "Priced at %.1f¢ at 1,000 kWh but %.1f¢ at 500 kWh and %.1f¢ at 2,000 kWh, because a bill credit only applies in a narrow usage range.",
                offer.price1000, offer.price500, offer.price2000
            )
            out.append(TrapWarning(kind: .billCreditCliff, title: "Bill-credit cliff", detail: detail, monthsMissingCredit: missing,
                                   values: [offer.price1000, offer.price500, offer.price2000]))
        }

        if let fee = terms?.minimumUsageFees.first {
            out.append(TrapWarning(
                kind: .minimumUsageFee, title: "Minimum-usage fee",
                detail: String(format: "Adds $%.2f in months you use less than %.0f kWh.", fee.amount, fee.belowKWh),
                monthsMissingCredit: [], values: [fee.amount, fee.belowKWh]
            ))
        }

        if offer.termMonths > 0 && offer.termMonths <= 3 {
            out.append(TrapWarning(
                kind: .teaserTerm, title: "Short contract",
                detail: "The rate lasts \(offer.termMonths) month\(offer.termMonths == 1 ? "" : "s"); after that you move to the provider's renewal rate unless you switch again.",
                monthsMissingCredit: [], values: [Double(offer.termMonths)]
            ))
        }

        if !offer.fixedRate {
            out.append(TrapWarning(
                kind: .variableRate, title: "Variable rate",
                detail: "The provider can change the price from month to month.",
                monthsMissingCredit: []
            ))
        }

        if offer.prepaid {
            out.append(TrapWarning(
                kind: .prepaid, title: "Prepaid",
                detail: "You pay in advance and service can be cut off quickly when the balance runs out.",
                monthsMissingCredit: []
            ))
        }

        if let fee = cancelFee(offer.cancelFee) {
            switch fee {
            case .flat(let amount) where amount > highCancelFee:
                out.append(TrapWarning(
                    kind: .highCancelFee, title: "High cancellation fee",
                    detail: String(format: "Leaving early costs $%.0f.", amount),
                    monthsMissingCredit: [], values: [amount]
                ))
            case .perRemainingMonth(let amount):
                out.append(TrapWarning(
                    kind: .highCancelFee, title: "Cancellation fee per month left",
                    detail: String(format: "Leaving early costs $%.0f for each month left on the contract.", amount),
                    monthsMissingCredit: [], values: [amount], perMonth: true
                ))
            default:
                break
            }
        }
        return out
    }

    /// Months whose usage falls outside every usage-based credit the plan offers.
    static func monthsMissingCredit(_ terms: PlanTerms?, _ months: [Double]) -> [Int] {
        guard let credits = terms?.credits.filter({ $0.minKWh > 0 || $0.maxKWh != nil }), !credits.isEmpty else { return [] }
        return months.indices.filter { i in !credits.contains { $0.applies(toKWh: months[i]) } }
    }

    enum CancelFee: Equatable {
        case flat(Double)
        case perRemainingMonth(Double)
    }

    /// The export writes "150.00", "0.00" or "20 / remaining month".
    static func cancelFee(_ text: String) -> CancelFee? {
        let lower = text.lowercased()
        let number = lower.firstMatch(of: /(\d+(?:\.\d+)?)/).flatMap { Double($0.1) }
        guard let number else { return nil }
        return lower.contains("month") ? .perRemainingMonth(number) : .flat(number)
    }
}
