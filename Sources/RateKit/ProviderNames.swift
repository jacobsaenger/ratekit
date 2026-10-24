import Foundation

extension PlanOffer {
    /// The provider's brand as customers know it ("SMARTENERGY HOLDINGS LLC" → "SmartEnergy").
    public var providerName: String { ProviderNames.display(provider) }
}

enum ProviderNames {
    /// Export spellings (upper-cased) → brand names, for every provider in the
    /// 2026-10-20 export. New providers fall back to `cleaned`.
    static let known: [String: String] = [
        "AE TEXAS": "AE Texas", "AMIGO ENERGY": "Amigo Energy", "AP GAS & ELECTRIC (TX) LLC": "AP Gas & Electric",
        "ABUNDANCE ENERGY": "Abundance Energy", "ATLANTEX POWER": "Atlantex Power", "BKV ENERGY": "BKV Energy",
        "BUDGET POWER": "Budget Power", "CHAMPION ENERGY SERVICES LLC": "Champion Energy", "CHARIOT ENERGY": "Chariot Energy",
        "CIRRO ENERGY": "Cirro Energy", "CONSTELLATION NEWENERGY INC": "Constellation", "CLEANSKY ENERGY": "CleanSky Energy",
        "COMPANION ENERGY": "Companion Energy", "DIRECT ENERGY": "Direct Energy", "DISCOUNT POWER": "Discount Power",
        "ENERGY TEXAS": "Energy Texas", "EXPRESS ENERGY": "Express Energy", "FRONTIER UTILITIES": "Frontier Utilities",
        "GEXA ENERGY": "Gexa Energy", "GOOD CHARLIE & CO LLC": "GoodCharlie", "GREEN MOUNTAIN ENERGY COMPANY": "Green Mountain Energy",
        "INFUSE ENERGY": "Infuse Energy", "JUST ENERGY": "Just Energy", "NEC CO-OP ENERGY": "NEC Co-op Energy",
        "OCTOPUS ENERGY": "Octopus Energy", "OCTOPUS ENERGY LLC": "Octopus Energy", "PAYLESS POWER": "Payless Power",
        "PRONTO POWER": "Pronto Power", "RELIANT": "Reliant", "REVOLUTION ENERGY LLC": "Revolution Energy", "RHYTHM": "Rhythm",
        "RANCHERO POWER": "Ranchero Power", "SFE ENERGY TEXAS INC": "SFE Energy", "SMARTENERGY HOLDINGS LLC": "SmartEnergy",
        "SOUTHERN FEDERAL POWER LLC": "Southern Federal Power", "SPARK ENERGY LLC": "Spark Energy", "TARA ENERGY": "Tara Energy",
        "TRIEAGLE ENERGY LP": "TriEagle Energy", "TRUE POWER": "True Power", "TXU ENERGY": "TXU Energy",
        "TEXANS CHOICE POWER LLC": "Texans Choice Power", "THINK ENERGY": "Think Energy", "VARSITY ENERGY LLC": "Varsity Energy",
        "VETERAN ENERGY": "Veteran Energy",
    ]

    static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return known[trimmed.uppercased()] ?? cleaned(trimmed)
    }

    /// Drops company suffixes and title-cases names written in capitals.
    static func cleaned(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: #"(?i)[,]?\s+(llc|l\.l\.c\.|lp|inc\.?|company|co\.?)$"#, with: "", options: .regularExpression)
        if name == name.uppercased() { name = name.capitalized }
        return name
    }
}
