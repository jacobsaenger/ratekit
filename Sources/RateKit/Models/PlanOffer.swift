import Foundation

/// The company that owns the wires in a service area. Its delivery charges are passed
/// through unchanged on every plan in that area.
public enum TDU: String, Codable, CaseIterable, Sendable {
    case oncor
    case oncorNTU
    case centerPoint
    case aepCentral
    case aepNorth
    case tnmp
    case lubbock
    case nueces

    /// Matches the `[TduCompanyName]` column of the Power to Choose export.
    public init?(powerToChooseName name: String) {
        switch name.uppercased() {
        case "ONCOR ELECTRIC DELIVERY COMPANY": self = .oncor
        case "ONCOR ELECTRIC DELIVERY COMPANY NTU LLC": self = .oncorNTU
        case "CENTERPOINT ENERGY HOUSTON ELECTRIC LLC": self = .centerPoint
        case "AEP TEXAS CENTRAL": self = .aepCentral
        case "AEP TEXAS NORTH": self = .aepNorth
        case "TEXAS-NEW MEXICO POWER COMPANY": self = .tnmp
        case "LUBBOCK POWER & LIGHT SYSTEM": self = .lubbock
        case "NUECES ELECTRIC COOPERATIVE": self = .nueces
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .oncor: "Oncor"
        case .oncorNTU: "Oncor (former Sharyland area)"
        case .centerPoint: "CenterPoint"
        case .aepCentral: "AEP Texas Central"
        case .aepNorth: "AEP Texas North"
        case .tnmp: "TNMP"
        case .lubbock: "Lubbock Power & Light"
        case .nueces: "Nueces Electric Cooperative"
        }
    }
}

/// One English row of the Power to Choose offers export. Prices are in cents per kWh.
public struct PlanOffer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tdu: TDU
    public var provider: String
    public var product: String
    public var price500: Double
    public var price1000: Double
    public var price2000: Double
    public var feesAndCredits: String
    public var prepaid: Bool
    public var timeOfUse: Bool
    public var fixedRate: Bool
    public var renewablePercent: Int
    public var termMonths: Int
    public var cancelFee: String
    public var website: String
    public var specialTerms: String
    public var termsURL: String
    public var yourRightsURL: String
    public var promotion: Bool
    public var promotionDescription: String
    public var factsURL: String
    public var enrollURL: String
    public var prepaidURL: String
    public var enrollPhone: String
    public var newCustomersOnly: Bool
    public var minimumUsageFeesOrCredits: Bool
    public var rating: Int?

    public init(
        id: String, tdu: TDU, provider: String, product: String,
        price500: Double, price1000: Double, price2000: Double,
        feesAndCredits: String = "", prepaid: Bool = false, timeOfUse: Bool = false,
        fixedRate: Bool = true, renewablePercent: Int = 0, termMonths: Int = 12,
        cancelFee: String = "", website: String = "", specialTerms: String = "",
        termsURL: String = "", yourRightsURL: String = "", promotion: Bool = false,
        promotionDescription: String = "", factsURL: String = "", enrollURL: String = "",
        prepaidURL: String = "", enrollPhone: String = "", newCustomersOnly: Bool = false,
        minimumUsageFeesOrCredits: Bool = false, rating: Int? = nil
    ) {
        self.id = id
        self.tdu = tdu
        self.provider = provider
        self.product = product
        self.price500 = price500
        self.price1000 = price1000
        self.price2000 = price2000
        self.feesAndCredits = feesAndCredits
        self.prepaid = prepaid
        self.timeOfUse = timeOfUse
        self.fixedRate = fixedRate
        self.renewablePercent = renewablePercent
        self.termMonths = termMonths
        self.cancelFee = cancelFee
        self.website = website
        self.specialTerms = specialTerms
        self.termsURL = termsURL
        self.yourRightsURL = yourRightsURL
        self.promotion = promotion
        self.promotionDescription = promotionDescription
        self.factsURL = factsURL
        self.enrollURL = enrollURL
        self.prepaidURL = prepaidURL
        self.enrollPhone = enrollPhone
        self.newCustomersOnly = newCustomersOnly
        self.minimumUsageFeesOrCredits = minimumUsageFeesOrCredits
        self.rating = rating
    }

    /// The provider's PUCT complaint score, 1 (highest complaint rate) to 5 (lowest), from
    /// the Retail Electric Provider Complaint Scorecard: providers ranked into five roughly
    /// equal groups by a rolling 6-month average of complaints. nil when unrated (the
    /// export's 0 or blank).
    public var complaintScore: Int? {
        guard let rating, (1...5).contains(rating) else { return nil }
        return rating
    }

    /// The published average price at one of the three Power to Choose usage levels.
    public func publishedPrice(atKWh kWh: Int) -> Double? {
        switch kWh {
        case 500: price500
        case 1000: price1000
        case 2000: price2000
        default: nil
        }
    }
}
