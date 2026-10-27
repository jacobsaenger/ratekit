import Foundation

/// The daily plan file the app downloads: every English residential offer from
/// Power to Choose, with the terms read from its Facts label when they verified.
public struct Feed: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var market: String
    public var generatedAt: Date
    /// The `TDUCharges` table date the feed was built with.
    public var deliveryChargesDate: String
    /// Each TDU's current pass-through delivery charges (keyed by `TDU` raw value), so a
    /// rate change reaches the app with the next feed rather than an app update. Older
    /// feeds without it fall back to the table compiled into the app.
    public var deliveryCharges: [String: TDUCharges]?
    public var plans: [FeedPlan]
    /// Each area's daily lowest price (keyed by `TDU` raw value), oldest first. Absent in
    /// feeds built before it was kept.
    public var priceHistory: [String: [PricePoint]]?
    /// The providers that pay us a referral fee, by provider display name, with what they
    /// pay ("$40 per sign-up"). Empty when none do; the app shows this on every plan page.
    public var referralFees: [String: String]?
    /// Each provider's last six months of PUCT complaints by type, keyed by the export's
    /// provider name (`PlanOffer.provider`). Absent in older feeds or when the pages failed.
    public var complaints: [String: ComplaintHistory]?

    /// The provider's own month-to-month or variable plans in an area: roughly what a fixed
    /// plan rolls onto if the household doesn't switch when it ends. Many providers list none.
    public func monthToMonthPlans(provider: String, tdu: TDU) -> [FeedPlan] {
        plans.filter {
            $0.offer.provider == provider && $0.offer.tdu == tdu && (!$0.offer.fixedRate || $0.offer.termMonths <= 1)
                && !$0.offer.prepaid && !$0.offer.timeOfUse
        }
            .sorted { $0.offer.price1000 < $1.offer.price1000 }
    }

    /// What the provider pays us when someone signs up through the app, or nil if nothing.
    public func referralFee(for provider: String) -> String? {
        referralFees?[provider]
    }

    public init(generatedAt: Date, plans: [FeedPlan]) {
        self.schemaVersion = Feed.currentSchemaVersion
        self.market = "TX"
        self.generatedAt = generatedAt
        self.deliveryChargesDate = TDUCharges.effectiveDate
        var charges: [String: TDUCharges] = [:]
        for tdu in TDU.allCases { charges[tdu.rawValue] = TDUCharges.current(tdu) }
        self.deliveryCharges = charges
        self.plans = plans
    }

    /// The TDU's delivery charges as of this feed.
    public func delivery(for tdu: TDU) -> TDUCharges? {
        deliveryCharges?[tdu.rawValue] ?? TDUCharges.current(tdu)
    }

    /// The feed is rebuilt once a day; a copy younger than this is not downloaded again.
    public static let refreshInterval: TimeInterval = 20 * 3600

    /// True when a newer feed may have been published since this one was built.
    public func isDueForRefresh(now: Date) -> Bool {
        now.timeIntervalSince(generatedAt) >= Feed.refreshInterval
    }

    public static func decode(_ data: Data) throws -> Feed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Feed.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct FeedPlan: Codable, Equatable, Sendable, Identifiable {
    public var offer: PlanOffer
    public var status: PlanStatus
    /// Present only when `status` is `.verified`.
    public var terms: PlanTerms?
    /// The label's answer on buying back excess solar generation; nil when it gives no
    /// plain yes or no (or the label could not be read).
    public var buysBackSolar: Bool?
    /// A time-of-use plan's windows and charges, when its label reproduced the published
    /// prices; priced only for households with time-of-day usage.
    public var timeOfUse: TimeOfUseTerms?
    /// Autopay or paperless billing the advertised price depends on, from the label and
    /// the plan's special terms.
    public var payment: PaymentRequirement?
    /// The sign-up link's check today; nil when it wasn't checked or couldn't be judged.
    public var enrollLink: LinkCheck?

    public var id: String { offer.id }

    public init(offer: PlanOffer, status: PlanStatus, terms: PlanTerms?, buysBackSolar: Bool? = nil) {
        self.offer = offer
        self.status = status
        self.terms = terms
        self.buysBackSolar = buysBackSolar
    }
}
