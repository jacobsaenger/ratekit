import XCTest
@testable import RateKit

final class ReferralFeeTests: XCTestCase {
    func testFeedSaysWhoPaysUs() throws {
        var feed = Feed(generatedAt: Date(timeIntervalSince1970: 0), plans: [])
        XCTAssertNil(feed.referralFee(for: "Reliant"))
        feed.referralFees = ["Gexa Energy": "$40 per sign-up"]
        let decoded = try Feed.decode(feed.encoded())
        XCTAssertEqual(decoded.referralFee(for: "Gexa Energy"), "$40 per sign-up")
        XCTAssertNil(decoded.referralFee(for: "Reliant"))
    }
}
