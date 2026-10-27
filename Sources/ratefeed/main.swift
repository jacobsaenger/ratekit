import Foundation
import RateKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage:
  ratefeed price <feed.json> <tdu> <home> [count]
      Prints the cheapest plans for a home estimate (UsageEstimate.Home raw value), all terms.
  ratefeed build --cache <dir> --out <feed.json> [--report <report.txt>] [--csv <offers.csv>] [--min-verified <n>] [--history <history.json>] [--referral-fees <referral-fees.json>] [--check-links] [--seed-labels <dir>] [--stats <stats.json>] [--complaints]
      Downloads the Power to Choose export (unless --csv is given) and every label not
      already in the cache, reads and checks each label, and writes the plan feed. With
      --min-verified, a run that verifies fewer plans fails without writing the feed.
      With --history, today's lowest price per area is added to that file and the
      feed carries the history. --seed-labels names a folder of label texts to use
      when a label can't be downloaded and none was cached (sites that block servers).
      --stats writes the day's counts (plans, priceable, verified, time-of-use) as JSON.
      --complaints adds each provider's six months of PUCT complaints by type.
  ratefeed check <offers.csv> <label-text-dir> [idKey ...]
      Reads each <idKey>.txt label in the directory and reports which plans verify.
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }

switch command {
case "check":
    guard args.count >= 3 else { fail(usage) }
    guard let csv = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("cannot read \(args[1])") }
    let dir = URL(fileURLWithPath: args[2])
    let only = Set(args.dropFirst(3))
    let offers = PowerToChooseCSV.offers(csv)
    var verified = 0, total = 0, timeOfUse = 0
    for offer in offers where only.isEmpty || only.contains(offer.id) {
        let file = dir.appendingPathComponent("\(offer.id).txt")
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let text = try? String(contentsOf: file, encoding: .utf8)
        let reading = PlanVerifier.read(offer, labelText: text)
        total += 1
        switch reading.status {
        case .verified:
            verified += 1
            print("OK    \(offer.id) \(offer.provider) | \(offer.product)")
            if !only.isEmpty, let text, let terms = reading.terms {
                print(LabelParser.facts(fromLabel: text, tdu: offer.tdu, feesAndCredits: offer.feesAndCredits))
                print(terms)
            }
        case .timeOfUse:
            timeOfUse += 1
            print("TOU   \(offer.id) \(offer.provider) | \(offer.product)")
        case .estimated(let reason):
            let miss = reading.closestMiss.map { String(format: "%.2f¢", $0) } ?? "-"
            print("MISS  \(offer.id) \(offer.provider) | \(offer.product) — \(reason), closest \(miss)")
            if !only.isEmpty, let text {
                print(LabelParser.facts(fromLabel: text, tdu: offer.tdu, feesAndCredits: offer.feesAndCredits))
                print("published", offer.price500, offer.price1000, offer.price2000)
            }
        }
    }
    let priced = total - timeOfUse
    let rate = priced > 0 ? Double(verified) / Double(priced) * 100 : 0
    print(String(format: "\nverified %d of %d priceable labels (%.1f%%); %d time-of-use (checked separately)", verified, priced, rate, timeOfUse))
case "price":
    guard args.count >= 4, let data = FileManager.default.contents(atPath: args[1]), let feed = try? Feed.decode(data),
          let tdu = TDU(rawValue: args[2]), let home = UsageEstimate.Home(rawValue: args[3]) else { fail(usage) }
    var all = PlanFilters()
    all.term = .any
    let ranking = PlanRanking(feed: feed, tdu: tdu, usage: UsageEstimate.estimate(for: home), filters: all)
    for p in ranking.ranked.prefix(args.count > 4 ? Int(args[4]) ?? 20 : 20) {
        print(String(format: "%@\t%.2f\t%@ | %@", p.id, p.annualCost, p.plan.offer.providerName, p.plan.offer.product))
    }
case "build":
    build(Array(args.dropFirst()))
default:
    fail(usage)
}
