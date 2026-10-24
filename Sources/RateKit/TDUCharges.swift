import Foundation

/// Delivery charges each TDU passes through unchanged on every plan in its area.
/// Used when a label points to a website instead of stating them, and to recognise
/// delivery figures in label tables that have no row names.
///
/// Source: the figures printed on the Facts labels in the 2026-10-20 Power to Choose
/// sample (most labels in each area agree to the hundredth of a cent). TDUs change these
/// about twice a year; `ratefeed` reports labels that disagree so the table can be updated.
public struct TDUCharges: Codable, Equatable, Sendable {
    public var perKWh: Double
    public var perMonth: Double

    public static let effectiveDate = "2026-10-20"

    public static func current(_ tdu: TDU) -> TDUCharges? {
        switch tdu {
        case .oncor: TDUCharges(perKWh: 6.8673, perMonth: 4.06)
        case .centerPoint: TDUCharges(perKWh: 6.5333, perMonth: 4.90)
        case .aepCentral: TDUCharges(perKWh: 5.6898, perMonth: 3.24)
        case .aepNorth: TDUCharges(perKWh: 5.5751, perMonth: 3.24)
        case .tnmp: TDUCharges(perKWh: 7.7710, perMonth: 7.56)
        case .lubbock: TDUCharges(perKWh: 6.3120, perMonth: 0)
        case .nueces: TDUCharges(perKWh: 4.79, perMonth: 32.50)
        case .oncorNTU: nil
        }
    }

    /// The charges before each TDU's last rate change. Some providers' Power to Choose prices
    /// still use them after their label was updated (BKV's CenterPoint plans on 2026-10-23
    /// fit 6.413¢ and no other figure), so the label check also tries them. Ranking always
    /// uses `current`. Source: the older figure still printed on a CenterPoint label in the
    /// 2026-10-23 export. Add an area only when a provider's prices are shown to fit it.
    public static func previous(_ tdu: TDU) -> TDUCharges? {
        switch tdu {
        case .centerPoint: TDUCharges(perKWh: 6.413, perMonth: 4.90)
        default: nil
        }
    }
}
