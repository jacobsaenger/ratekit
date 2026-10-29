import Foundation

/// "What if": a change coming at the home, as the kWh it adds (or saves) in each month.
/// The figures are from EIA's 2020 Residential Energy Consumption Survey for Texas, the US
/// Department of Energy and the Federal Highway Administration, as noted on each.
public enum HomeChange: String, CaseIterable, Codable, Sendable {
    case electricCar
    case poolVariableSpeed
    case poolSingleSpeed
    case newAirConditioner
    case heatPump

    static let daysInMonth: [Double] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    /// kWh in a million Btu.
    static let kWhPerMMBtu = 293.07

    /// FHWA Highway Statistics 2024, Table VM-1: a car's average miles a year.
    public static let carMilesPerYear = 11_026.0
    /// kWh a mile, inside DOE's range for 2024 midsize electric cars (2.17–4.17 miles a kWh).
    public static let carKWhPerMile = 0.30
    /// DOE Building America pool pump guide: kWh a day, run every day of the year.
    public static let singleSpeedPumpKWhPerDay = 12.6
    public static let variableSpeedPumpKWhPerDay = 2.2
    /// EIA RECS 2020 (CE8.7.M, Texas): average electric cooling, million Btu a month.
    public static let texasCoolingMMBtu = [0.1, 0.1, 0.5, 0.6, 1.4, 2.2, 2.9, 2.8, 1.7, 0.9, 0.3, 0.1]
    /// EIA RECS 2020 (CE8.6.M, Texas): average electric space heating, million Btu a month
    /// (the summer months, not reported, as none).
    public static let texasHeatingMMBtu = [1.6, 1.7, 0.4, 0.4, 0, 0, 0, 0, 0.1, 0.5, 0.7, 2.1]
    /// DOE's example: an old SEER 10 air conditioner replaced with a SEER 15 one.
    public static let oldSEER = 10.0, newSEER = 15.0
    /// The federal minimum HSPF2 for split heat pumps since 2023. Resistance heat gives one
    /// unit of heat per unit of power, an HSPF of 3.412.
    public static let heatPumpHSPF2 = 7.5, resistanceHSPF = 3.412

    /// kWh added in each month, January first; negative where the change saves power.
    public var monthlyKWh: [Double] {
        switch self {
        case .electricCar:
            return Self.daysInMonth.map { Self.carMilesPerYear * Self.carKWhPerMile * $0 / 365 }
        case .poolVariableSpeed:
            return Self.daysInMonth.map { $0 * Self.variableSpeedPumpKWhPerDay }
        case .poolSingleSpeed:
            return Self.daysInMonth.map { $0 * Self.singleSpeedPumpKWhPerDay }
        case .newAirConditioner:
            return Self.texasCoolingMMBtu.map { -$0 * Self.kWhPerMMBtu * (1 - Self.oldSEER / Self.newSEER) }
        case .heatPump:
            return Self.texasHeatingMMBtu.map { -$0 * Self.kWhPerMMBtu * (1 - Self.resistanceHSPF / Self.heatPumpHSPF2) }
        }
    }

    /// The year's usage with the change: each month moved by the change, never below zero.
    public func applied(to usage: YearOfUsage) -> YearOfUsage {
        var changed = usage
        changed.kWh = zip(usage.kWh, monthlyKWh).map { max(0, $0 + $1) }
        return changed
    }
}
