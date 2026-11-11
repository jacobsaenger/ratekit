import Foundation

/// Solar buyback programs Texas providers sell, mostly on their own sites rather than on
/// Power to Choose, checked by hand against each provider's page, Facts label or Terms of
/// Service (the `source` of each entry). The list goes stale and is refreshed by hand.
public struct SolarBuybackProgram: Codable, Equatable, Sendable, Identifiable {
    /// How power sent out is credited.
    public enum Credit: String, Codable, Sendable {
        /// A fixed ¢ per kWh (`cents`).
        case fixed
        /// The plan's own energy charge, kWh for kWh.
        case energyRate
        /// A fixed rate below the plan's energy charge, stated on its Facts label.
        case belowEnergyRate
        /// The real-time wholesale price, up to `capCents` if there is one.
        case wholesale
        /// Rates by time of day (`periods`).
        case timeOfDay
        /// Stated on the plan's Facts label, which wasn't readable.
        case onLabel
        /// Not published on the provider's page.
        case notPublished
    }

    public struct Period: Codable, Equatable, Sendable {
        /// "offPeak", "onPeak", "ultraOnPeak".
        public var name: String
        public var cents: Double
    }

    public var id: String
    public var provider: String
    public var program: String
    public var credit: Credit
    public var cents: Double?
    public var capCents: Double?
    public var periods: [Period]?
    /// Credits stop at the month's grid use.
    public var cappedAtUsage: Bool?
    /// Credits can only pay the energy charge, not the base charge, delivery or taxes.
    public var energyChargeOnly: Bool?
    /// Sold only to customers of one solar installer (Vivint).
    public var vivintOnly: Bool?
    /// A below-the-energy-rate credit whose rate the plan's Facts label states.
    public var rateOnLabel: Bool?
    /// Added to the provider's listed plans rather than sold as its own plan.
    public var addOn: Bool?
    /// The delivery area of the Facts label the rates came from.
    public var labelArea: String?
    /// The date of the Facts label the rates came from, when older than the check.
    public var asOf: String?
    public var source: String

    /// Dollars a year for `exportKWh` sent out, when the credit is a known fixed rate.
    public func yearlyCredit(exportKWh: Double) -> Double? {
        guard credit == .fixed, let cents else { return nil }
        return exportKWh * cents / 100
    }
}

public enum SolarBuyback {
    public struct List: Codable, Sendable {
        /// The day the programs were checked (yyyy-MM-dd).
        public var checked: String
        public var programs: [SolarBuybackProgram]
    }

    /// The bundled list, with fixed-rate programs first (highest rate first).
    public static let list: List = {
        guard let url = Bundle.module.url(forResource: "solar-buyback", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var list = try? JSONDecoder().decode(List.self, from: data) else { return List(checked: "", programs: []) }
        list.programs = list.programs.enumerated().sorted { a, b in
            let ra = a.element.credit == .fixed ? a.element.cents ?? 0 : -1, rb = b.element.credit == .fixed ? b.element.cents ?? 0 : -1
            return ra != rb ? ra > rb : a.offset < b.offset
        }.map(\.element)
        return list
    }()
}
