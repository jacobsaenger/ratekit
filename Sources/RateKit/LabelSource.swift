import Foundation

/// Turning a label link or page into text the reader can use.
public enum LabelSource {
    /// Vistra's brands (Express, TriEagle, Veteran) link to a page that builds the label in
    /// the browser from `/api/getdocument`; this is that request, which returns the PDF.
    public static func vistraDocumentURL(_ page: URL, date: Date) -> URL? {
        guard page.path.lowercased().hasSuffix("/pdfgenerator"),
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let product = q["comprodid"], let tdsp = q["tdsp"] else { return nil }
        let day = ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "America/Chicago")!, formatOptions: [.withFullDate])
        parts.path = "/api/getdocument"
        parts.queryItems = [
            URLQueryItem(name: "docType", value: q["formtype"] ?? "EnergyFactsLabel"),
            URLQueryItem(name: "productid", value: product),
            URLQueryItem(name: "efldate", value: day + "T00:00:00"),
            URLQueryItem(name: "tdsp", value: tdsp),
            URLQueryItem(name: "language", value: q["lang"] ?? "en"),
            URLQueryItem(name: "classification", value: q["custclass"] ?? "Residential"),
        ]
        return parts.url
    }

    /// The visible text of an HTML label, one block per line.
    public static func htmlText(_ html: String) -> String {
        var t = html
        for pattern in [#"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<!--.*?-->"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"(?i)<(br|/p|/div|/tr|/li|/h\d|/td|/th|/section)\b[^>]*>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&cent;": "¢", "&#162;": "¢"]
        for (e, c) in entities { t = t.replacingOccurrences(of: e, with: c) }
        return t
    }

    /// Octopus Energy's label page embeds its rates as JSON (`__NEXT_DATA__` →
    /// `eflSnapshot.snapshotData.rates`; TDU monthly charge in cents) and states a $5.00
    /// autopay credit in its page template, which every Octopus label shows. Returns the
    /// label as the text lines the reader expects, or nil if the page is not one of these.
    public static func octopusText(_ html: String) -> String? {
        guard let open = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let page = props["pageProps"] as? [String: Any],
              let snapshot = page["eflSnapshot"] as? [String: Any],
              let data = snapshot["snapshotData"] as? [String: Any],
              let rates = data["rates"] as? [String: Any],
              let energy = (rates["energyCharge"] as? String).flatMap(Double.init),
              let tduKWh = (rates["serviceProviderConsumptionRate"] as? String).flatMap(Double.init),
              let tduMonthCents = (rates["serviceProviderStandingRate"] as? String).flatMap(Double.init)
        else { return nil }
        let baseCents = (rates["monthlySubscriptionFees"] as? String).flatMap(Double.init) ?? 0
        return """
        Electricity Facts Label (EFL)
        Energy Charge \(energy)¢ per kWh
        TDU Delivery Charge \(tduKWh)¢ per kWh
        TDU Delivery Charge $\(String(format: "%.2f", tduMonthCents / 100)) per month
        Base Charge $\(String(format: "%.2f", baseCents / 100)) per month
        Autopay Discount $5.00 per billing cycle
        """
    }

    /// The label's answer to "Does the provider purchase excess distributed renewable
    /// generation?" (solar buyback): true, false, or nil when it gives no plain yes or no.
    public static func buysBackSolar(_ text: String) -> Bool? {
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.lowercased().contains("purchase excess distributed") }) else { return nil }
        let question = lines[i].lowercased()
        let start = question.range(of: "does")?.lowerBound ?? question.startIndex
        // The answer sits on the question's line, the next line, or between its two halves.
        let window = ([String(question[start...])] + lines.dropFirst(i + 1).prefix(2).map { $0.lowercased() })
            .joined(separator: " ")
        guard let m = window.firstMatch(of: /\b(yes|no)\b/) else { return nil }
        return m.1 == "yes"
    }
}
