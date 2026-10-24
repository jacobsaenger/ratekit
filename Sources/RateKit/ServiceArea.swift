import Foundation

/// Which delivery company serves a ZIP code, from the bundled `zip-tdu.json`
/// (built by `scripts/build-zip-table.py` from ERCOT's meter extract).
public enum ServiceArea: Equatable, Sendable {
    /// One delivery company serves the ZIP.
    case single(TDU)
    /// Several do; the user picks the one named on their bill. Largest share first.
    case split([TDU])
    /// A Texas ZIP with no retail choice (a city utility, a co-op, or a utility outside
    /// the competitive market).
    case noChoice
    /// Not a Texas ZIP code.
    case notTexas

    public static func lookup(_ zip: String, in table: ZIPTable = .bundled) -> ServiceArea {
        let digits = zip.trimmingCharacters(in: .whitespaces)
        guard digits.count == 5, let n = Int(digits) else { return .notTexas }
        // Texas ZIPs are 75000–79999 plus 885xx (El Paso).
        guard (75000...79999).contains(n) || (88500...88599).contains(n) else { return .notTexas }
        guard let tdus = table.zips[digits], let first = tdus.first else { return .noChoice }
        return tdus.count == 1 ? .single(first) : .split(tdus)
    }
}

public struct ZIPTable: Sendable {
    public var zips: [String: [TDU]]

    public init(zips: [String: [TDU]]) { self.zips = zips }

    public static let bundled: ZIPTable = {
        guard let url = Bundle.module.url(forResource: "zip-tdu", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? decode(data)
        else { return ZIPTable(zips: [:]) }
        return table
    }()

    public static func decode(_ data: Data) throws -> ZIPTable {
        struct Entry: Decodable { var tdu: String }
        struct Doc: Decodable { var zips: [String: [Entry]] }
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        return ZIPTable(zips: doc.zips.mapValues { $0.compactMap { TDU(rawValue: $0.tdu) } })
    }
}
