import Foundation
import RateKit

func build(_ args: [String]) {
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let cachePath = option("--cache"), let outPath = option("--out") else { fail(usage) }
    let cache = URL(fileURLWithPath: cachePath)
    let labels = cache.appendingPathComponent("labels")
    let seeds = option("--seed-labels").map { URL(fileURLWithPath: $0) }
    try? FileManager.default.createDirectory(at: labels, withIntermediateDirectories: true)

    let csvData: Data
    if let local = option("--csv") {
        guard let d = FileManager.default.contents(atPath: local) else { fail("cannot read \(local)") }
        csvData = d
    } else {
        guard let d = download(powerToChooseExport, timeout: 120) else { fail("Power to Choose export download failed") }
        csvData = d
        try? d.write(to: cache.appendingPathComponent("offers-latest.csv"))
    }
    guard let csv = String(data: csvData, encoding: .utf8) else { fail("export is not UTF-8") }
    let offers = PowerToChooseCSV.offers(csv)
    // A live export this small is a broken download; a file given with --csv is deliberate.
    guard offers.count > 100 || option("--csv") != nil else { fail("export has only \(offers.count) English offers; refusing to build") }

    var plans: [FeedPlan] = []
    var misses: [(PlanOffer, String, Double?)] = []
    var downloads = 0
    var fallbacks = 0
    var used: Set<String> = []
    for (n, offer) in offers.enumerated() {
        used.insert(labelCacheKey(offer))
        used.insert(lastGoodKey(offer))
        let (text, problem) = labelText(for: offer, in: labels, seeds: seeds, downloads: &downloads, fallbacks: &fallbacks)
        var reading = PlanVerifier.read(offer, labelText: text)
        if let problem, reading.status != .timeOfUse { reading = PlanReading(status: .estimated(reason: problem)) }
        var plan = FeedPlan(offer: offer, status: reading.status, terms: reading.terms,
                            buysBackSolar: text.flatMap(LabelSource.buysBackSolar))
        if offer.timeOfUse, let text { plan.timeOfUse = TimeOfUseReader.read(offer, labelText: text) }
        plan.payment = PaymentTerms.read(labelText: text, specialTerms: offer.specialTerms)
        plans.append(plan)
        if case .estimated(let reason) = reading.status { misses.append((offer, reason, reading.closestMiss)) }
        if (n + 1) % 100 == 0 { FileHandle.standardError.write(Data("\(n + 1)/\(offers.count) plans, \(downloads) labels downloaded\n".utf8)) }
    }

    // Labels cached under keys this export no longer uses (prices changed, plan gone).
    // Only after a full live export: a local or partial --csv must not empty the cache.
    if option("--csv") == nil {
    for file in (try? FileManager.default.contentsOfDirectory(atPath: labels.path)) ?? [] {
        let key = (file as NSString).deletingPathExtension
        if !used.contains(key) { try? FileManager.default.removeItem(at: labels.appendingPathComponent(file)) }
    }
    }

    // Sign-up links, checked once per distinct address.
    if args.contains("--check-links") {
        let urls = Set(plans.compactMap { URL(string: $0.offer.enrollURL.trimmingCharacters(in: .whitespaces)) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") })
        let checks = checkLinks(urls)
        for i in plans.indices {
            if let url = URL(string: plans[i].offer.enrollURL.trimmingCharacters(in: .whitespaces)) { plans[i].enrollLink = checks[url] }
        }
        let counted = Dictionary(grouping: checks.values, by: \.status).mapValues(\.count)
        FileHandle.standardError.write(Data("sign-up links: \(urls.count) checked, \(counted[.ok] ?? 0) ok, \(counted[.homepage] ?? 0) home page, \(counted[.broken] ?? 0) broken\n".utf8))
    }

    var report = buildReport(plans, misses: misses)
    // "Every plan on Power to Choose is listed" holds only if no English row was dropped.
    let englishRows = PowerToChooseCSV.englishRowCount(csv)
    if englishRows != offers.count {
        report += "\n\n\(englishRows - offers.count) English rows in the export were skipped (unknown service area or unreadable prices)."
    }
    if fallbacks > 0 {
        report += "\n\n\(fallbacks) labels could not be downloaded today and were read from their last good copy."
    }
    print(report)
    if let reportPath = option("--report") { try? report.write(toFile: reportPath, atomically: true, encoding: .utf8) }

    // A run that verifies far fewer plans than usual (a changed export or label format,
    // a blocked download) must not replace the published feed.
    let verified = plans.filter { $0.status == .verified }.count
    if let minimum = option("--min-verified").flatMap(Int.init), verified < minimum {
        fail("only \(verified) plans verified (minimum \(minimum)); feed not written")
    }
    let now = Date()
    var feed = Feed(generatedAt: now, plans: plans)
    // The lowest price per area each day, kept in a file the workflow carries between runs.
    if let historyPath = option("--history") {
        var old: [String: [PricePoint]] = [:]
        if let data = FileManager.default.contents(atPath: historyPath) {
            // A history that exists but can't be read must not be replaced by today alone.
            do { old = try JSONDecoder().decode([String: [PricePoint]].self, from: data) }
            catch { fail("cannot read \(historyPath): \(error)") }
        }
        let history = PriceHistory.merged(old, adding: PriceHistory.points(for: feed, on: now), now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try encoder.encode(history).write(to: URL(fileURLWithPath: historyPath)) } catch { fail("cannot write \(historyPath): \(error)") }
        feed.priceHistory = history
    }
    // Who pays us, from the repo's referral-fees.json ({"Provider": "$40 per sign-up"}).
    if let path = option("--referral-fees") {
        guard let data = FileManager.default.contents(atPath: path),
              let fees = try? JSONDecoder().decode([String: String].self, from: data) else { fail("cannot read \(path)") }
        // A name that matches no provider would make its plans say we earn nothing from them.
        let names = Set(plans.map(\.offer.providerName))
        let unknown = fees.keys.filter { !names.contains($0) }.sorted()
        guard unknown.isEmpty else { fail("\(path) names providers not in the feed: \(unknown.joined(separator: ", "))") }
        feed.referralFees = fees
    }
    // What people complain to the PUCT about, per provider (`--complaints`).
    if args.contains("--complaints") {
        let providers = Set(plans.map(\.offer.provider))
        let complaints = fetchComplaints(providers: providers)
        feed.complaints = complaints.isEmpty ? nil : complaints
        FileHandle.standardError.write(Data("complaint histories: \(complaints.count) of \(providers.count) providers\n".utf8))
    }
    do { try feed.encoded().write(to: URL(fileURLWithPath: outPath)) } catch { fail("cannot write \(outPath): \(error)") }
    // Today's check in a few numbers, for the website to show without loading the feed.
    if let statsPath = option("--stats") {
        struct Stats: Encodable {
            var date: String, plans: Int, priceable: Int, verified: Int, timeOfUse: Int, timeOfUseConfirmed: Int
        }
        let tou = plans.filter { $0.status == .timeOfUse }.count
        let day = ISO8601DateFormatter.string(from: now, timeZone: TimeZone(identifier: "America/Chicago")!, formatOptions: [.withFullDate])
        let stats = Stats(date: day, plans: plans.count, priceable: plans.count - tou, verified: verified,
                          timeOfUse: tou, timeOfUseConfirmed: plans.filter { $0.timeOfUse != nil }.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try encoder.encode(stats).write(to: URL(fileURLWithPath: statsPath)) } catch { fail("cannot write \(statsPath): \(error)") }
    }
}

/// The label's text, from the cache or freshly downloaded. Returns a reason instead when
/// the label cannot be read.
/// The label's text: freshly read, or, when the provider's site fails, the last copy that
/// was read successfully. A stale copy is safe to use because the plan still has to
/// reproduce today's published prices to be verified.
///
/// `seeds` holds copies, committed to the repo, of labels whose sites refuse cloud servers
/// (Tara, Amigo, Ranchero and others; the list is in scripts/refresh-seed-labels.py): read
/// from the Mac, used when the job has never downloaded the label itself.
func labelText(for offer: PlanOffer, in dir: URL, seeds: URL? = nil, downloads: inout Int, fallbacks: inout Int) -> (String?, String?) {
    let lastGood = dir.appendingPathComponent(lastGoodKey(offer) + ".txt")
    let (text, problem) = freshLabelText(for: offer, in: dir, downloads: &downloads)
    if let text {
        try? text.write(to: lastGood, atomically: true, encoding: .utf8)
        return (text, nil)
    }
    if let old = try? String(contentsOf: lastGood, encoding: .utf8) {
        fallbacks += 1
        return (old, nil)
    }
    if let seeds, let seed = try? String(contentsOf: seeds.appendingPathComponent(lastGoodKey(offer) + ".txt"), encoding: .utf8) {
        fallbacks += 1
        return (seed, nil)
    }
    return (nil, problem)
}

/// The last successfully read text for a label link, whatever its prices were then.
func lastGoodKey(_ offer: PlanOffer) -> String { "last-" + cacheKey(offer.factsURL) }

func freshLabelText(for offer: PlanOffer, in dir: URL, downloads: inout Int) -> (String?, String?) {
    guard let url = labelURL(offer.factsURL) else { return (nil, "label link is invalid") }
    // A label is re-read when its published prices change, and at least weekly: a
    // provider can replace the label behind the same link.
    let key = labelCacheKey(offer)
    let raw = dir.appendingPathComponent(key + ".bin")
    let txt = dir.appendingPathComponent(key + ".txt")
    // The daily job caches only the text, so its age stands in for the download's.
    let stamp = FileManager.default.fileExists(atPath: raw.path) ? raw : txt
    let modified = (try? FileManager.default.attributesOfItem(atPath: stamp.path)[.modificationDate]) as? Date
    if let modified, Date().timeIntervalSince(modified) > 7 * 24 * 3600 {
        try? FileManager.default.removeItem(at: raw)
        try? FileManager.default.removeItem(at: txt)
    }
    if let cached = try? String(contentsOf: txt, encoding: .utf8) { return (cached, nil) }

    var data = FileManager.default.contents(atPath: raw.path)
    if data == nil {
        Thread.sleep(forTimeInterval: 0.5)
        data = download(url)
        downloads += 1
        guard let d = data else { return (nil, "label download failed") }
        try? d.write(to: raw)
    }
    guard var data else { return (nil, "label download failed") }
    if !data.starts(with: Array("%PDF".utf8)), let doc = LabelSource.vistraDocumentURL(url, date: Date()) {
        Thread.sleep(forTimeInterval: 0.5)
        downloads += 1
        guard let pdf = download(doc), pdf.starts(with: Array("%PDF".utf8)) else { return (nil, "label download failed") }
        data = pdf
        try? pdf.write(to: raw)
    }
    let text: String
    if data.starts(with: Array("%PDF".utf8)) {
        guard let t = pdfText(raw), t.count > 200 else { return (nil, "label PDF has no text") }
        text = t
    } else {
        let html = String(decoding: data, as: UTF8.self)
        let t = LabelSource.octopusText(html) ?? LabelSource.htmlText(html)
        guard t.lowercased().contains("facts label"), t.contains("¢") else { return (nil, "label is a web page without its prices") }
        text = t
    }
    try? text.write(to: txt, atomically: true, encoding: .utf8)
    return (text, nil)
}

/// Labels are cached by link and published prices, so a price change re-reads the label.
func labelCacheKey(_ offer: PlanOffer) -> String {
    cacheKey("\(offer.factsURL)|\(offer.price500)|\(offer.price1000)|\(offer.price2000)")
}

func buildReport(_ plans: [FeedPlan], misses: [(PlanOffer, String, Double?)]) -> String {
    let tou = plans.filter { $0.status == .timeOfUse }.count
    let verified = plans.filter { $0.status == .verified }.count
    let priceable = plans.count - tou
    var lines: [String] = []
    let touConfirmed = plans.filter { $0.timeOfUse != nil }.count
    lines.append(String(format: "verified %d of %d priceable plans (%.1f%%); %d of %d time-of-use plans confirmed (priced for 15-minute usage); %d plans total",
                        verified, priceable, Double(verified) / Double(max(priceable, 1)) * 100, touConfirmed, tou, plans.count))

    var reasons: [String: Int] = [:]
    for m in misses { reasons[m.1, default: 0] += 1 }
    lines.append("\nNot verified, by reason:")
    for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) { lines.append("  \(count)  \(reason)") }

    lines.append("\nBy provider (verified / priceable):")
    var byProvider: [String: (Int, Int)] = [:]
    for p in plans where p.status != .timeOfUse {
        var v = byProvider[p.offer.provider, default: (0, 0)]
        v.1 += 1
        if p.status == .verified { v.0 += 1 }
        byProvider[p.offer.provider] = v
    }
    for (provider, v) in byProvider.sorted(by: { ($0.value.1 - $0.value.0) > ($1.value.1 - $1.value.0) }) where v.0 < v.1 {
        lines.append("  \(v.0)/\(v.1)  \(provider)")
    }

    lines.append("\nVerified plans whose delivery charges differ from the TDU table (\(TDUCharges.effectiveDate)):")
    var differ: [TDU: Int] = [:]
    for p in plans {
        guard let t = p.terms, let table = TDUCharges.current(p.offer.tdu), t.deliveryPerKWh != 0 else { continue }
        if abs(t.deliveryPerKWh - table.perKWh) > 0.00005 || abs(t.deliveryPerMonth - table.perMonth) > 0.005 {
            differ[p.offer.tdu, default: 0] += 1
        }
    }
    lines.append(differ.isEmpty ? "  none" : differ.map { "  \($0.value)  \($0.key.displayName)" }.sorted().joined(separator: "\n"))

    // Fees below 500 kWh change none of the three published prices, so the label's
    // wording alone decides them; list them for a look.
    let unseenFees = plans.filter { $0.terms?.minimumUsageFees.contains { $0.belowKWh <= 500 } ?? false }
    lines.append("\nVerified plans with a minimum-usage fee the published prices cannot check (\(unseenFees.count)):")
    for p in unseenFees.prefix(40) {
        let fees = p.terms!.minimumUsageFees.map { String(format: "$%.2f below %.0f kWh", $0.amount, $0.belowKWh) }.joined(separator: ", ")
        lines.append("  \(p.offer.id)  \(p.offer.provider) | \(p.offer.product) — \(fees)")
    }

    lines.append("\nMisses:")
    for m in misses.sorted(by: { $0.0.provider < $1.0.provider }) {
        let miss = m.2.map { String(format: ", closest %.2f¢", $0) } ?? ""
        lines.append("  \(m.0.id)  \(m.0.provider) | \(m.0.product) — \(m.1)\(miss)")
    }
    return lines.joined(separator: "\n")
}
