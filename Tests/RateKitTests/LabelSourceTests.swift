import XCTest
@testable import RateKit

final class LabelSourceTests: XCTestCase {
    func testVistraPageBecomesDocumentRequest() throws {
        let page = URL(string: "https://shopping.myexpressenergy.com/PDFGenerator?formType=EnergyFactsLabel&comProdId=TCEXFLASHCC12IL&tdsp=AEPTCC&lang=en&custClass=Residential")!
        // 2026-10-20 18:00 UTC is still the 20th in Texas.
        let url = try XCTUnwrap(LabelSource.vistraDocumentURL(page, date: Date(timeIntervalSince1970: 1_792_519_200)))
        XCTAssertEqual(url.absoluteString, "https://shopping.myexpressenergy.com/api/getdocument?docType=EnergyFactsLabel&productid=TCEXFLASHCC12IL&efldate=2026-10-20T00:00:00&tdsp=AEPTCC&language=en&classification=Residential")
        XCTAssertNil(LabelSource.vistraDocumentURL(URL(string: "https://example.com/efl.pdf")!, date: Date()))
    }

    func testHTMLLabelReadsLikeAPDFLabel() {
        // Octopus Energy's label page, reduced to the price rows.
        let html = """
        <html><head><script>var x = "9.99¢";</script></head><body>
        <div>Electricity Facts Label (EFL)</div>
        <div>Average price per kWh:</div><div>14.5&cent;</div><div>15.0&cent;</div><div>15.3&cent;</div>
        <div><p>Octopus Energy Charge</p><p>9.2068¢ per kWh</p></div>
        <div><p>LPL Charge per kWh</p><p>6.3120¢ per kWh</p></div>
        <div><p>LPL per meter Fee</p><p>$0.00 per month</p></div>
        <div><p>Base Charge:</p><p>$0.00 per month</p></div>
        <div><p>Autopay Discount:</p><p>$5.00 per billing cycle</p></div>
        </body></html>
        """
        let text = LabelSource.htmlText(html)
        XCTAssertFalse(text.contains("9.99"))
        let facts = LabelParser.facts(fromLabel: text, tdu: .lubbock)
        XCTAssertEqual(facts.energyRates, [9.2068])
        XCTAssertEqual(facts.deliveryPerKWh, [6.312])
        XCTAssertEqual(facts.credits, [UsageCredit(amount: 5)])
        let offer = PlanOffer(id: "x", tdu: .lubbock, provider: "Octopus Energy", product: "Octo Simple 8",
                              price500: 14.5, price1000: 15.0, price2000: 15.3)
        XCTAssertEqual(PlanVerifier.read(offer, labelText: text).status, .verified)
    }
}

final class OctopusLabelTests: XCTestCase {
    func testRatesFromPageData() throws {
        let html = #"""
        <html><body><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"eflSnapshot":{"snapshotData":{"rates":{"energyCharge":"9.20680","serviceProviderConsumptionRate":"6.31200","serviceProviderStandingRate":"0.00000","monthlySubscriptionFees":"0"}}}}}}</script></body></html>
        """#
        let text = try XCTUnwrap(LabelSource.octopusText(html))
        let facts = LabelParser.facts(fromLabel: text, tdu: .lubbock)
        XCTAssertEqual(facts.energyRates, [9.2068])
        XCTAssertEqual(facts.deliveryPerKWh, [6.312])
        XCTAssertEqual(facts.deliveryPerMonth, [0])
        XCTAssertEqual(facts.credits, [UsageCredit(amount: 5)])
        // Octo Simple 8, Lubbock, as its label page showed it on 2026-10-20.
        let offer = PlanOffer(id: "x", tdu: .lubbock, provider: "Octopus Energy", product: "Octo Simple 8",
                              price500: 14.5, price1000: 15.0, price2000: 15.3)
        XCTAssertEqual(PlanVerifier.read(offer, labelText: text).status, .verified)
        XCTAssertNil(LabelSource.octopusText("<html>no data</html>"))
    }
}

final class SolarBuybackTests: XCTestCase {
    func testAnswerOnTheSameLineTheNextLineOrBetweenTheHalves() {
        XCTAssertEqual(LabelSource.buysBackSolar("Is this a pre-pay product? No\nDoes Pronto purchase excess distributed renewable generation? No\n"), false)
        XCTAssertEqual(LabelSource.buysBackSolar("Does Revolution Energy purchase excess distributed\n No\n renewable generation?"), false)
        XCTAssertEqual(LabelSource.buysBackSolar("Does the REP purchase excess distributed Yes\n renewable generation?"), true)
        XCTAssertEqual(LabelSource.buysBackSolar("Does Champion purchase excess distributed Yes; if you own or lease on-site solar\nrenewable generation?"), true)
    }

    func testConditionalOrMissingAnswersAreNotGuessed() {
        // A pre-pay "No" before the question must not be taken as its answer.
        XCTAssertNil(LabelSource.buysBackSolar("Is this a pre-pay product? No\nDoes REP purchase excess distributed Renewable energy sell back product availability is subject to\nrenewable generation? change at Cirro Energy's discretion.\nRenewable Content 22%"))
        XCTAssertNil(LabelSource.buysBackSolar("Energy Charge 9.0¢ per kWh"))
    }
}

final class NewFilterTests: XCTestCase {
    func offer(_ id: String, rating: Int?) -> PlanOffer {
        PlanOffer(id: id, tdu: .oncor, provider: id, product: id, price500: 0, price1000: 0, price2000: 0, termMonths: 12, rating: rating)
    }

    func testSolarAndComplaintFilters() {
        let terms = PlanTerms(energyRate: 8, deliveryPerKWh: 6.8673, deliveryPerMonth: 4.06)
        let solar = FeedPlan(offer: offer("solar", rating: 5), status: .verified, terms: terms, buysBackSolar: true)
        let noSolar = FeedPlan(offer: offer("nosolar", rating: 2), status: .verified, terms: terms, buysBackSolar: false)
        let unrated = FeedPlan(offer: offer("unrated", rating: 0), status: .verified, terms: terms, buysBackSolar: nil)
        var f = PlanFilters()
        f.solarBuybackOnly = true
        XCTAssertEqual([solar, noSolar, unrated].filter(f.allows).map(\.id), ["solar"])
        f = PlanFilters(); f.hideHighComplaintProviders = true
        XCTAssertEqual([solar, noSolar, unrated].filter(f.allows).map(\.id), ["solar", "unrated"])
        XCTAssertNil(unrated.offer.complaintScore)
    }

    func testFiltersSavedBeforeTheNewKeysStillLoad() throws {
        let old = #"{"term":"any","fixedRateOnly":true,"minimumRenewablePercent":50,"hidePrepaid":true,"hideMinimumUsageFees":false}"#
        let f = try JSONDecoder().decode(PlanFilters.self, from: Data(old.utf8))
        XCTAssertEqual(f.term, .any)
        XCTAssertTrue(f.fixedRateOnly)
        XCTAssertEqual(f.minimumRenewablePercent, 50)
        XCTAssertFalse(f.solarBuybackOnly)
        XCTAssertFalse(f.hideHighComplaintProviders)
    }
}

/// Wordings from real labels (2026-10-22).
final class PaymentTermsTests: XCTestCase {
    func testCreditFeeAndRequirementWordings() {
        XCTAssertEqual(PaymentTerms.read(labelText: "Auto Pay & Paperless Credit: $5.00 per month\nThe Auto Pay and Paperless Communication Credit will not be applied to any billing cycle in which you opt out."),
                       PaymentRequirement(autopay: true, paperless: true, feeIfNot: 5))
        XCTAssertEqual(PaymentTerms.read(labelText: "You will incur a fee of $5.00 per billing period if you are not enrolled\nin Autopay. Information on other charges"),
                       PaymentRequirement(autopay: true, paperless: false, feeIfNot: 5))
        XCTAssertEqual(PaymentTerms.read(labelText: "Other Key Terms and Autopay required. See Terms of Service"),
                       PaymentRequirement(autopay: true, paperless: false, feeIfNot: nil))
        XCTAssertEqual(PaymentTerms.read(labelText: "Other Terms and This plan requires paperless billing and communication."),
                       PaymentRequirement(autopay: false, paperless: true, feeIfNot: nil))
    }

    func testTheNearestAmountNotADeliveryChargeOnTheSameLine() {
        let octopus = "TDU Delivery Charge 5.7164¢ per kWh TDU Delivery Charge $3.24 per month Base Charge $0.00 per month Autopay Discount $5.00 per billing cycle"
        XCTAssertEqual(PaymentTerms.read(labelText: octopus)?.feeIfNot, 5)
    }

    func testPaperlessProductWording() {
        XCTAssertEqual(PaymentTerms.read(labelText: "This is a paperless product. See Terms of Service."),
                       PaymentRequirement(autopay: false, paperless: true, feeIfNot: nil))
    }

    func testOptionalAutopayIsNotARequirement() {
        XCTAssertNil(PaymentTerms.read(labelText: "Electronic Billing and auto payment via bank draft, credit card, or debit card available."))
        XCTAssertNil(PaymentTerms.read(labelText: "Energy Charge 9.0¢ per kWh"))
    }

    func testTheRequirementBecomesAWarningAndAFilter() {
        let offer = PlanOffer(id: "a", tdu: .oncor, provider: "A", product: "A", price500: 0, price1000: 0, price2000: 0)
        let w = TrapRules.warnings(for: offer, terms: nil, payment: PaymentRequirement(autopay: true, paperless: false, feeIfNot: 5))
        XCTAssertEqual(w.first?.kind, .paymentRequirement)
        XCTAssertEqual(w.first?.values, [5, 1, 0])
        var plan = FeedPlan(offer: offer, status: .verified, terms: PlanTerms(energyRate: 10, deliveryPerKWh: 0, deliveryPerMonth: 0))
        plan.payment = PaymentRequirement(autopay: true, paperless: false, feeIfNot: 5)
        var filters = PlanFilters()
        XCTAssertTrue(filters.allows(plan))
        filters.hidePaymentRequirements = true
        XCTAssertFalse(filters.allows(plan))
    }
}

final class LinkCheckTests: XCTestCase {
    func testClassification() {
        let plan = URL(string: "https://shop.example.com/path2plans?prom=X")!
        XCTAssertEqual(LinkCheck.classify(original: plan, final: plan, statusCode: 200)?.status, .ok)
        XCTAssertEqual(LinkCheck.classify(original: plan, final: URL(string: "https://example.com/"), statusCode: 200)?.status, .homepage)
        // A bare link to begin with isn't judged: it can be the sign-up form itself.
        XCTAssertNil(LinkCheck.classify(original: URL(string: "https://signup.example.com/")!, final: nil, statusCode: 200))
        XCTAssertEqual(LinkCheck.classify(original: plan, final: plan, statusCode: 404)?.status, .broken)
        XCTAssertNil(LinkCheck.classify(original: plan, final: plan, statusCode: 403))
        XCTAssertNil(LinkCheck.classify(original: plan, final: nil, statusCode: nil))
    }
}
