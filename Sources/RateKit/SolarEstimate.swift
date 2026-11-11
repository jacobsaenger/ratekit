import Foundation

/// "Should I get solar?": what a rooftop system would make where the household lives, how
/// much of its usage that covers, and what it does to a year on a plan. Output is NREL
/// PVWatts for a city in each delivery area (4 kW, standard module, fixed roof, 20° tilt,
/// facing south, 14% losses), kept in the app so nothing about the household is sent.
public struct SolarEstimate: Equatable, Sendable {
    /// kWh a kW of panels makes in each month, January first.
    static let houston = [92.8, 87.7, 128.7, 126.6, 137.5, 134.7, 139.6, 134.2, 122.8, 121.7, 109.1, 86.0]
    static let dallas = [100.6, 98.4, 123.3, 133.5, 142.4, 151.0, 154.6, 150.3, 136.5, 118.4, 98.4, 98.7]
    static let corpusChristi = [96.1, 103.3, 132.9, 130.6, 143.8, 148.1, 153.0, 153.6, 129.4, 130.8, 104.4, 96.5]
    static let abilene = [118.2, 112.1, 148.2, 152.6, 156.3, 158.2, 159.2, 147.9, 142.8, 131.6, 116.1, 106.3]
    static let midland = [125.2, 128.9, 156.8, 162.0, 164.1, 163.0, 163.0, 159.9, 144.2, 142.8, 122.7, 114.1]

    /// LBNL's 2025 medians for a home system bought outright and for all owned systems, $ per watt
    /// before incentives.
    public static let costPerWatt = 3.0...3.6

    /// The cities whose output stands for each area.
    public enum City: String, Sendable {
        case houston = "Houston", dallas = "Dallas", corpusChristi = "Corpus Christi", abilene = "Abilene", midland = "Midland"
    }

    /// The city for the household's area. West Texas ZIPs (795–799) on Oncor or TNMP, and
    /// Lubbock, use Midland's.
    public static func city(tdu: TDU, zip: String) -> City {
        let west = ["795", "796", "797", "798", "799"].contains(where: zip.hasPrefix)
        switch tdu {
        case .centerPoint: return .houston
        case .tnmp: return west ? .midland : .houston
        case .aepCentral, .nueces: return .corpusChristi
        case .aepNorth: return .abilene
        case .lubbock: return .midland
        case .oncor, .oncorNTU: return west ? .midland : .dallas
        }
    }

    public static func kWhPerKW(tdu: TDU, zip: String) -> [Double] {
        switch city(tdu: tdu, zip: zip) {
        case .houston: houston
        case .dallas: dallas
        case .corpusChristi: corpusChristi
        case .abilene: abilene
        case .midland: midland
        }
    }

    public var kW: Double
    /// kWh the panels make, January first.
    public var production: [Double]
    /// Of that, kWh used at home as it's made (never more than the month's usage), and sent out.
    public var usedAtHome: [Double]
    public var exported: [Double]
    /// The year on the plan without and with the panels, dollars. With them, the household
    /// buys only what the panels don't cover and is paid `buybackCents` for what it sends out.
    public var yearWithout: Double
    public var yearWith: Double

    public var yearlySaving: Double { yearWithout - yearWith }
    public var yearlyProduction: Double { production.reduce(0, +) }
    /// The share of the year's usage the panels make (can be over 1).
    public var coverage: Double
    /// What the system would cost at LBNL's medians, low to high.
    public var cost: ClosedRange<Double> { kW * 1000 * Self.costPerWatt.lowerBound...kW * 1000 * Self.costPerWatt.upperBound }
    /// Years for the saving to repay the cost, low to high; nil when it saves nothing.
    public var paybackYears: ClosedRange<Double>? {
        guard yearlySaving > 1 else { return nil }
        return cost.lowerBound / yearlySaving...cost.upperBound / yearlySaving
    }

    /// `usedAsMade` is the share of the panels' output used at home as it's made (the rest
    /// goes out to the grid); it depends on when the household uses power, which monthly
    /// bills don't show. `buybackCents` is what a plan pays per kWh sent out.
    public init(kW: Double, tdu: TDU, zip: String, usage: YearOfUsage, terms: PlanTerms,
                usedAsMade: Double, buybackCents: Double) {
        let perKW = Self.kWhPerKW(tdu: tdu, zip: zip)
        let share = min(max(usedAsMade, 0), 1)
        self.kW = kW
        production = perKW.map { $0 * kW }
        usedAtHome = Swift.zip(production, usage.kWh).map { min($0 * share, $1) }
        exported = Swift.zip(production, usedAtHome).map { $0 - $1 }
        let bought = Swift.zip(usage.kWh, usedAtHome).map { $0 - $1 }
        yearWithout = CostEngine.annualCost(terms, monthlyKWh: usage.kWh)
        yearWith = CostEngine.annualCost(terms, monthlyKWh: bought) - exported.reduce(0, +) * max(buybackCents, 0) / 100
        let total = usage.kWh.reduce(0, +)
        coverage = total > 0 ? production.reduce(0, +) / total : 0
    }
}
