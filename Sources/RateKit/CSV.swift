import Foundation

/// RFC 4180 CSV: quoted fields may hold commas, doubled quotes and line breaks.
public enum CSV {
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = n }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

public enum PowerToChooseCSV {
    /// How many rows of the export are in English, read or not.
    public static func englishRowCount(_ text: String) -> Int {
        let all = CSV.rows(text)
        guard let header = all.first,
              let language = header.firstIndex(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\u{FEFF}")) == "Language" })
        else { return 0 }
        return all.dropFirst().filter { language < $0.count && $0[language].trimmingCharacters(in: .whitespacesAndNewlines) == "English" }.count
    }

    /// The English residential offers in a Power to Choose export. Rows for unknown
    /// service areas, other languages, or with unreadable prices are skipped.
    public static func offers(_ text: String) -> [PlanOffer] {
        let all = CSV.rows(text)
        guard let header = all.first else { return [] }
        let names = header.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\u{FEFF}")) }
        var index: [String: Int] = [:]
        for (i, name) in names.enumerated() { index[name] = i }

        return all.dropFirst().compactMap { row in
            func v(_ key: String) -> String {
                guard let i = index[key], i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func flag(_ key: String) -> Bool { v(key).lowercased() == "true" || v(key) == "1" }
            func cents(_ key: String) -> Double? { Double(v(key)).map { $0 * 100 } }

            guard v("Language") == "English",
                  let tdu = TDU(powerToChooseName: v("TduCompanyName")),
                  let p500 = cents("kwh500"), let p1000 = cents("kwh1000"), let p2000 = cents("kwh2000")
            else { return nil }

            return PlanOffer(
                id: v("idKey"), tdu: tdu, provider: v("RepCompany"), product: v("Product"),
                price500: p500, price1000: p1000, price2000: p2000,
                feesAndCredits: v("Fees/Credits"), prepaid: flag("PrePaid"), timeOfUse: flag("TimeOfUse"),
                fixedRate: v("RateType") == "Fixed", renewablePercent: Int(v("Renewable")) ?? 0,
                termMonths: Int(v("TermValue")) ?? 0, cancelFee: v("CancelFee"), website: v("Website"),
                specialTerms: v("SpecialTerms"), termsURL: v("TermsURL"), yourRightsURL: v("YRACURL"),
                promotion: flag("Promotion"), promotionDescription: v("PromotionDesc"),
                factsURL: v("FactsURL"), enrollURL: v("EnrollURL"), prepaidURL: v("PrepaidURL"),
                enrollPhone: v("EnrollPhone"), newCustomersOnly: flag("NewCustomer"),
                minimumUsageFeesOrCredits: flag("MinUsageFeesCredits"), rating: Int(v("Rating"))
            )
        }
    }
}
