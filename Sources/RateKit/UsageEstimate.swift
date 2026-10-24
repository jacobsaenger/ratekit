import Foundation

/// Twelve months of usage, January first, with a flag for each month that is estimated
/// rather than taken from the household's own bills or meter.
public struct YearOfUsage: Equatable, Codable, Sendable {
    public var kWh: [Double]
    public var estimated: [Bool]

    public init(kWh: [Double], estimated: [Bool]) {
        precondition(kWh.count == 12 && estimated.count == 12)
        self.kWh = kWh
        self.estimated = estimated
    }

    public var total: Double { kWh.reduce(0, +) }
}

/// Fills in missing months and estimates a home's usage when it has no history.
public enum UsageEstimate {
    /// Each month's share of a year's Texas residential electricity use, January first:
    /// EIA-861M retail sales to the residential sector in Texas, 2023–2025, each year's
    /// monthly share averaged over the three years. Fetched from the EIA API v2
    /// (electricity/retail-sales, stateid TX, sectorid RES) on 2026-10-20.
    public static let texasMonthlyShare: [Double] = [
        0.0841092, 0.0718295, 0.0611270, 0.0591686, 0.0738443, 0.0982256,
        0.1157597, 0.1224628, 0.1033802, 0.0807110, 0.0614135, 0.0679688,
    ]

    /// Fills the months missing from `known` (month index 0–11 → kWh) by scaling the
    /// Texas seasonal shape to the months the household does know.
    public static func fill(_ known: [Int: Double]) -> YearOfUsage? {
        let valid = known.filter { (0..<12).contains($0.key) && $0.value >= 0 }
        guard !valid.isEmpty else { return nil }
        let knownShare = valid.keys.reduce(0) { $0 + texasMonthlyShare[$1] }
        let annual = valid.values.reduce(0, +) / knownShare
        let kWh = (0..<12).map { valid[$0] ?? (annual * texasMonthlyShare[$0]).rounded() }
        let estimated = (0..<12).map { valid[$0] == nil }
        return YearOfUsage(kWh: kWh, estimated: estimated)
    }

    public enum Home: String, CaseIterable, Codable, Sendable {
        case apartment, townhome, mobileHome
        case houseUnder1000, house1000to1499, house1500to1999, house2000to2499, house2500to2999, house3000plus

        /// Average yearly kWh for homes like this in the South census region, from EIA
        /// RECS 2020 table CE2.4 (revised March 2024). Texas homes average 13,440 kWh
        /// (table CE4.6.EL.ST), close to the region's 13,376, so the region's split is used.
        public var annualKWh: Double {
            switch self {
            case .apartment: 8068        // apartment in a building with 5+ units
            case .townhome: 10312        // single-family attached
            case .mobileHome: 14804
            case .houseUnder1000: 9281
            case .house1000to1499: 11673
            case .house1500to1999: 13761
            case .house2000to2499: 15266
            case .house2500to2999: 16725
            case .house3000plus: 19542
            }
        }
    }

    /// A whole estimated year for a home with no usage history.
    public static func estimate(for home: Home) -> YearOfUsage {
        YearOfUsage(
            kWh: texasMonthlyShare.map { (home.annualKWh * $0).rounded() },
            estimated: Array(repeating: true, count: 12)
        )
    }
}
