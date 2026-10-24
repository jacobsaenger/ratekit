import Foundation

/// The pricing parts of a plan, read from its Electricity Facts Label.
/// Cents per kWh (`¢`) and dollars per month (`$`) throughout.
public struct PlanTerms: Codable, Equatable, Sendable {
    /// $ per month, including daily customer fees converted to 30 days.
    public var baseCharge: Double
    /// Energy price bands, applied block by block. A plan with one rate has one band
    /// starting at 0 kWh.
    public var energyTiers: [EnergyTier]
    /// ¢ per kWh, passed through from the TDU.
    public var deliveryPerKWh: Double
    /// $ per month, passed through from the TDU.
    public var deliveryPerMonth: Double
    public var credits: [UsageCredit]
    public var minimumUsageFees: [MinimumUsageFee]
    /// $ charged once to enroll ("One-time GoodBundle set up … $49.99"). Labels that state
    /// one spread 1/12 of it over each month of their average prices, and so does the
    /// cost engine, which makes a year's cost include it exactly once.
    public var oneTimeFee: Double?

    public init(
        baseCharge: Double = 0,
        energyTiers: [EnergyTier],
        deliveryPerKWh: Double,
        deliveryPerMonth: Double,
        credits: [UsageCredit] = [],
        minimumUsageFees: [MinimumUsageFee] = [],
        oneTimeFee: Double? = nil
    ) {
        self.baseCharge = baseCharge
        self.energyTiers = energyTiers
        self.deliveryPerKWh = deliveryPerKWh
        self.deliveryPerMonth = deliveryPerMonth
        self.credits = credits
        self.minimumUsageFees = minimumUsageFees
        self.oneTimeFee = oneTimeFee
    }

    /// A plan with one energy rate.
    public init(
        baseCharge: Double = 0,
        energyRate: Double,
        deliveryPerKWh: Double,
        deliveryPerMonth: Double,
        credits: [UsageCredit] = [],
        minimumUsageFees: [MinimumUsageFee] = []
    ) {
        self.init(
            baseCharge: baseCharge,
            energyTiers: [EnergyTier(fromKWh: 0, rate: energyRate)],
            deliveryPerKWh: deliveryPerKWh,
            deliveryPerMonth: deliveryPerMonth,
            credits: credits,
            minimumUsageFees: minimumUsageFees
        )
    }
}

/// Energy charged at `rate` ¢/kWh for each kWh above `fromKWh`, up to the next band.
public struct EnergyTier: Codable, Equatable, Sendable {
    public var fromKWh: Double
    public var rate: Double

    public init(fromKWh: Double, rate: Double) {
        self.fromKWh = fromKWh
        self.rate = rate
    }
}

/// A bill credit of `amount` dollars for months whose usage is inside the range.
/// `minKWh` is inclusive and `maxKWh` (if any) is inclusive; a credit with neither
/// applies every month (for example an autopay credit).
public struct UsageCredit: Codable, Equatable, Sendable {
    public var amount: Double
    public var minKWh: Double
    public var maxKWh: Double?

    public init(amount: Double, minKWh: Double = 0, maxKWh: Double? = nil) {
        self.amount = amount
        self.minKWh = minKWh
        self.maxKWh = maxKWh
    }

    public func applies(toKWh kWh: Double) -> Bool {
        kWh >= minKWh && (maxKWh.map { kWh <= $0 } ?? true)
    }
}

/// A fee of `amount` dollars for months whose usage is below `belowKWh` (exclusive).
public struct MinimumUsageFee: Codable, Equatable, Sendable {
    public var amount: Double
    public var belowKWh: Double

    public init(amount: Double, belowKWh: Double) {
        self.amount = amount
        self.belowKWh = belowKWh
    }
}
