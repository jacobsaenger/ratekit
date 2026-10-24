import XCTest
@testable import RateKit

final class LabelParserTests: XCTestCase {
    // MARK: Money figures

    func testAmountUnits() {
        XCTAssertEqual(Amount.scan("nerg Charge $0.0719 per kWh"), [Amount(value: 7.19, unit: .cents)])
        XCTAssertEqual(Amount.scan("Energy Charge: $ 0.020475 per kilowatt-hour").first?.value ?? 0, 2.0475, accuracy: 1e-9)
        let daily = Amount.scan(LabelParser.normalized("Daily Customer Fee (DCF) $0.39 cents per day ($11.70 per 30 days)"))
        XCTAssertEqual(daily.map(\.unit), [.dollars, .dollars])
        XCTAssertEqual(daily[0].value, 11.7, accuracy: 1e-9)
        XCTAssertEqual(daily[1].value, 11.7, accuracy: 1e-9)
        XCTAssertEqual(Amount.scan("Residential Usage Credit 35.00 $ per bill month"), [Amount(value: 35, unit: .dollars)])
        XCTAssertEqual(
            Amount.scan(LabelParser.normalized("CenterPoint Energy 6.5333 cents/kWh and $4.90 per month")),
            [Amount(value: 6.5333, unit: .cents), Amount(value: 4.9, unit: .dollars)]
        )
    }

    // MARK: Thresholds

    func testCreditThresholdWording() {
        func c(_ context: String) -> UsageCredit? { LabelParser.credit(amount: 100, context: context) }
        XCTAssertEqual(c("credit: $100.00 if your usage on this plan is equal or greater than 1000 kwh per bill cycle."), UsageCredit(amount: 100, minKWh: 1000))
        XCTAssertEqual(c("100.00 $ per bill month if usage >= 1000kwh"), UsageCredit(amount: 100, minKWh: 1000))
        XCTAssertEqual(c("$100 credit when usage exceeds 1000 kwh"), UsageCredit(amount: 100, minKWh: 1001))
        XCTAssertEqual(c("$100 credit when usage is between 1000 and 2000 kwh"), UsageCredit(amount: 100, minKWh: 1000, maxKWh: 2000))
        XCTAssertEqual(c("auto pay & paperless credit: $100.00 per month"), UsageCredit(amount: 100))
        XCTAssertEqual(c("usage credit $100 for 1,000kwh or more"), UsageCredit(amount: 100, minKWh: 1000))
        XCTAssertEqual(c("$100 credit for 1001+ kwh"), UsageCredit(amount: 100, minKWh: 1001))
    }

    /// Upper limits (review of 2026-10-20): each of these used to lose its upper limit.
    func testCreditUpperLimits() {
        func c(_ context: String) -> UsageCredit? { LabelParser.credit(amount: 100, context: context) }
        let band = UsageCredit(amount: 100, minKWh: 1000, maxKWh: 2000)
        XCTAssertEqual(c("usage credit: $100 if usage is greater than or equal to 1000 kwh and less than or equal to 2000 kwh."), band)
        XCTAssertEqual(c("$100 credit when usage >= 1000 kwh and <= 2000 kwh"), band)
        XCTAssertEqual(c("$100 credit when usage is at least 1000 kwh but not more than 2000 kwh"), band)
        XCTAssertEqual(c("bill credit $100 for usage from 1000 kwh to less than 2001 kwh"), band)
        XCTAssertEqual(c("bill credit $100 for usage from 1000 kwh to 2000 kwh"), band)
        XCTAssertEqual(c("$100 credit for usage up to 999 kwh"), UsageCredit(amount: 100, minKWh: 0, maxKWh: 999))
    }

    func testUnclearLimitsAreRejected() {
        func c(_ context: String) -> UsageCredit? { LabelParser.credit(amount: 100, context: context) }
        XCTAssertNil(c("$100 credit when usage is at least 1000 kwh or at least 750 kwh"))   // two lower limits
        XCTAssertNil(c("$100 credit when usage is at least 2000 kwh and less than 1000 kwh"))  // crossing
        XCTAssertNil(c("$100 credit on a 1000 kwh bill"))                                       // no comparison
    }

    func testMinimumUsageThreshold() {
        XCTAssertEqual(LabelParser.threshold(below: "a minimum usage fee of $4.99 will apply to billing cycles less than 400 kwh."), 400)
        XCTAssertEqual(LabelParser.threshold(below: "minimum usage fee of $9.95 per month when usage is 499 kwh or less."), 500)
        XCTAssertEqual(LabelParser.threshold(below: "a $9.95 fee applies if usage is less than or equal to 499 kwh"), 500)
        XCTAssertNil(LabelParser.threshold(below: "a minimum usage fee of $9.95 applies"))
    }

    /// A credit's limits come from its own sentence, not the lines after it.
    func testCreditLimitsStayInTheirOwnSentence() {
        let lines = ["usage credit $125 when usage is 1000 kwh or more per billing cycle.",
                     "customers must use at least 750 kwh for the loyalty reward."]
        XCTAssertEqual(LabelParser.ownSentence(lines, at: 0), lines[0])
        let wrapped = ["smart choice credit: $125.00 if your usage on this plan is equal or greater",
                       "than 1000 kwh per bill cycle.", "pass-through tdsp charge: $3.24 per month"]
        XCTAssertEqual(LabelParser.credit(amount: 125, context: LabelParser.ownSentence(wrapped, at: 0)), UsageCredit(amount: 125, minKWh: 1000))
    }

    /// End to end: a label whose wording once misled the reader either verifies with the
    /// true terms or is shown as estimated. It must never verify with wrong terms.
    func testMisleadingWordingNeverVerifiesWrong() {
        let base = "Energy Charge 12.0¢ per kWh\nTDU Delivery Charge 6.5333¢ per kWh\nTDU Delivery Charge $4.90 per month\n"
        func plan(_ credits: [UsageCredit] = [], fees: [MinimumUsageFee] = []) -> PlanTerms {
            PlanTerms(energyRate: 12, deliveryPerKWh: 6.5333, deliveryPerMonth: 4.90, credits: credits, minimumUsageFees: fees)
        }
        let cases: [(String, PlanTerms)] = [
            ("Usage Credit: $100 if usage is greater than or equal to 1000 kWh and less than or equal to 2000 kWh.\n",
             plan([UsageCredit(amount: 100, minKWh: 1000, maxKWh: 2000)])),
            ("Usage Credit $125 when usage is 1000 kWh or more per billing cycle.\nCustomers must use at least 750 kWh for the Loyalty Reward.\n",
             plan([UsageCredit(amount: 125, minKWh: 1000)])),
            ("Minimum Usage Fee of $9.95 per month when usage is 499 kWh or less.\n",
             plan(fees: [MinimumUsageFee(amount: 9.95, belowKWh: 500)])),
            ("Usage Credit: $50 per month when usage exceeds 1000 kWh.\nAdditional Usage Credit: $100 per month when usage is at least 2000 kWh.\n",
             plan([UsageCredit(amount: 50, minKWh: 1001), UsageCredit(amount: 100, minKWh: 2000)])),
            ("Autopay Credit: $5.00 per month\nMinimum Usage Fee $9.95 if usage less than 500 kWh\n",
             plan([UsageCredit(amount: 5)], fees: [MinimumUsageFee(amount: 9.95, belowKWh: 500)])),
            // Round 2: two credits on one line, one written as a range.
            ("Usage Credit: $60 for usage of 2100 kWh or more; $30 for usage of 1100-1900 kWh.\n",
             plan([UsageCredit(amount: 60, minKWh: 2100), UsageCredit(amount: 30, minKWh: 1100, maxKWh: 1900)])),
            ("Usage Credit: $30 for usage of 1100-1900 kWh; $60 for usage of 2100 kWh or more.\n",
             plan([UsageCredit(amount: 30, minKWh: 1100, maxKWh: 1900), UsageCredit(amount: 60, minKWh: 2100)])),
            ("Bill credit of $50 when usage is between 1,000 and 2,000 kWh.\n",
             plan([UsageCredit(amount: 50, minKWh: 1000, maxKWh: 2000)])),
            ("If usage exceeds 999 kWh you receive a $100 credit.\n",
             plan([UsageCredit(amount: 100, minKWh: 1000)])),
        ]
        var verified = 0
        for (label, truth) in cases {
            func rounded(_ k: Double) -> Double { (CostEngine.averagePrice(truth, kWh: k) * 10).rounded() / 10 }
            let offer = PlanOffer(id: "x", tdu: .centerPoint, provider: "P", product: "Test",
                                  price500: rounded(500), price1000: rounded(1000), price2000: rounded(2000))
            let reading = PlanVerifier.read(offer, labelText: base + label)
            if reading.status == .verified {
                verified += 1
                XCTAssertEqual(reading.terms?.credits, truth.credits, label)
                XCTAssertEqual(reading.terms?.minimumUsageFees, truth.minimumUsageFees, label)
            }
        }
        // Most of these should read correctly; a reader that gives up on all of them
        // would pass the check above and be useless.
        XCTAssertGreaterThanOrEqual(verified, 6)
    }

    // MARK: Whole labels

    func testBillCreditLabel() throws {
        let facts = LabelParser.facts(fromLabel: try Fixtures.text("efl/33364.txt"), tdu: .oncor)
        XCTAssertEqual(facts.energyRates, [12.127])
        XCTAssertEqual(facts.baseCharges, [0])
        XCTAssertEqual(facts.deliveryPerKWh.first ?? 0, 6.8673, accuracy: 1e-9)
        XCTAssertEqual(facts.deliveryPerMonth, [4.06])
        XCTAssertEqual(facts.credits, [UsageCredit(amount: 125, minKWh: 1000)])
    }

    func testDeliveryChargesFromTableWhenLabelLinksToWebsite() throws {
        // SFE lists its TDU charges on a web page; the reader falls back to the TDU table.
        let facts = LabelParser.facts(fromLabel: try Fixtures.text("efl/35179.txt"), tdu: .aepNorth)
        XCTAssertTrue(facts.deliveryPerKWh.isEmpty)
        let options = LabelParser.candidates(from: facts, tdu: .aepNorth)
        XCTAssertTrue(options.contains { $0.deliveryPerKWh == 5.5751 && $0.deliveryPerMonth == 3.24 && $0.energyTiers == [EnergyTier(fromKWh: 0, rate: 5.47)] })
    }

    func testUnlabelledTableRowUsesTDUFigures() throws {
        // Champion prints "7.5¢/kWh $0.00 7.7100¢/kWh $7.56" under column headings.
        let facts = LabelParser.facts(fromLabel: try Fixtures.text("efl/16543.txt"), tdu: .tnmp)
        XCTAssertTrue(facts.energyRates.contains(7.5))
        XCTAssertTrue(facts.deliveryPerKWh.contains(7.71))
        XCTAssertTrue(facts.deliveryPerMonth.contains(7.56))
    }

    /// Every fixture label either verifies or is a known, explained miss. A new miss here
    /// means a parser change broke a label that used to read correctly.
    func testFixtureLabelsVerify() throws {
        let offers = PowerToChooseCSV.offers(try Fixtures.text("ptc-2026-10-20.csv"))
        let index = try JSONDecoder().decode([FixtureEntry].self, from: Data(contentsOf: Fixtures.url("efl/index.json")))
        let knownMisses: [String: String] = [
            "29285": "label links to a website for TDU charges and its prices use older ones",
            "33674": "variable rate not printed on the label",
            "36758": "variable rate not printed on the label",
        ]
        var verified = 0, priceable = 0
        for entry in index where entry.format == "pdf" {
            let offer = try XCTUnwrap(offers.first { $0.id == entry.idKey })
            let reading = PlanVerifier.read(offer, labelText: try Fixtures.text("efl/\(entry.idKey).txt"))
            if reading.status == .timeOfUse { continue }
            priceable += 1
            if reading.status == .verified {
                verified += 1
                XCTAssertNil(knownMisses[entry.idKey], "\(entry.idKey) now verifies; remove it from knownMisses")
            } else {
                XCTAssertNotNil(knownMisses[entry.idKey], "\(entry.idKey) \(entry.provider) | \(entry.product) no longer verifies")
            }
        }
        XCTAssertEqual(priceable, 51)
        XCTAssertEqual(verified, 48)
    }

    func testLabelForAnotherServiceAreaIsNotVerified() {
        let label = "Electricity Facts Label\nSmartEnergy\nAEP Texas North\nEnergy Charge 5.0¢ per kWh\nTDU Delivery Charges 5.5751¢ per kWh\nTDU Delivery Charges $3.24 per month\n"
        let offer = PlanOffer(id: "x", tdu: .aepCentral, provider: "P", product: "T", price500: 11.2, price1000: 10.9, price2000: 10.7)
        XCTAssertEqual(PlanVerifier.read(offer, labelText: label).status, .estimated(reason: "label is for another service area"))
        XCTAssertFalse(LabelServiceArea.namesOnlyAnother(label, tdu: .aepNorth))
        XCTAssertFalse(LabelServiceArea.namesOnlyAnother("Electricity Facts Label\nEnergy Charge 5.0¢", tdu: .aepNorth))
    }

    /// Just Energy's bundle (2026-10-23): a required $49.99 setup the label spreads 1/12 a
    /// month over its averages. A year's cost includes it once.
    func testOneTimeFeeIsSpreadOverTheYear() throws {
        let offer = PlanOffer(id: "24634", tdu: .aepCentral, provider: "JUST ENERGY", product: "Sustainable Living Bundle - 3",
                              price500: 10.4, price1000: 9.6, price2000: 9.3)
        let reading = PlanVerifier.read(offer, labelText: try Fixtures.text("efl/24634.txt"))
        XCTAssertEqual(reading.status, .verified)
        let terms = try XCTUnwrap(reading.terms)
        XCTAssertEqual(terms.oneTimeFee, 49.99)
        var without = terms
        without.oneTimeFee = nil
        let year = [Double](repeating: 1000, count: 12)
        XCTAssertEqual(CostEngine.annualCost(terms, monthlyKWh: year) - CostEngine.annualCost(without, monthlyKWh: year), 49.99, accuracy: 1e-9)
    }

    /// Tara's copy of the same bundle says the setup "includes 2000 lbs. of carbon credits":
    /// an offset bought for the customer, not a bill credit.
    func testCarbonCreditsAreNotABillCredit() throws {
        let offer = PlanOffer(id: "22762", tdu: .aepCentral, provider: "TARA ENERGY", product: "Sustainable Home Bundle - 3",
                              price500: 10.4, price1000: 9.6, price2000: 9.3)
        let reading = PlanVerifier.read(offer, labelText: try Fixtures.text("efl/22762.txt"))
        XCTAssertEqual(reading.status, .verified)
        XCTAssertEqual(reading.terms?.credits, [])
    }

    /// BKV's label prints CenterPoint's current 6.5333¢, but its Power to Choose prices
    /// (14.2, 13.7, 13.4) were worked out with the previous 6.413¢. The plan verifies on its
    /// own energy charge and is still ranked with today's delivery.
    func testPricesFromBeforeTheLastDeliveryChangeVerify() throws {
        let offer = PlanOffer(id: "29410", tdu: .centerPoint, provider: "BKV Energy", product: "Daisy 12",
                              price500: 14.2, price1000: 13.7, price2000: 13.4)
        let reading = PlanVerifier.read(offer, labelText: try Fixtures.text("efl/29410.txt"))
        XCTAssertEqual(reading.status, .verified)
        let terms = try XCTUnwrap(reading.terms)
        XCTAssertEqual(terms.energyTiers.first?.rate, 6.783)
        XCTAssertEqual(terms.deliveryPerKWh, 6.413)
        XCTAssertEqual(PlanRanking.withCurrentDelivery(terms, charges: TDUCharges.current(.centerPoint)).deliveryPerKWh, 6.5333)
    }

    func testTimeOfUsePlansAreNotPriced() throws {
        let offers = PowerToChooseCSV.offers(try Fixtures.text("ptc-2026-10-20.csv"))
        let txu = try XCTUnwrap(offers.first { $0.id == "33717" })
        XCTAssertEqual(PlanVerifier.read(txu, labelText: try Fixtures.text("efl/33717.txt")).status, .timeOfUse)
    }
}

private struct FixtureEntry: Decodable {
    var idKey: String
    var provider: String
    var product: String
    var format: String
}
