import XCTest
@testable import StremioSkeletonCore

final class PlaybackHTTPRangeResponsePolicyTests: XCTestCase {
    func testAcceptsMatchingPartialContentBeforeProgressiveBodyDelivery() {
        XCTAssertEqual(
            PlaybackHTTPRangeResponsePolicy.validate(
                statusCode: 206,
                contentRange: "bytes 2-17/64",
                expectedLowerBound: 2,
                expectedUpperBound: 17,
                expectedTotalLength: 64
            ),
            .accepted
        )
    }

    func testRejectsServerThatIgnoresRangeBeforeBodyDelivery() {
        XCTAssertEqual(
            PlaybackHTTPRangeResponsePolicy.validate(
                statusCode: 200,
                contentRange: nil,
                expectedLowerBound: 2,
                expectedUpperBound: 17,
                expectedTotalLength: 64
            ),
            .invalidStatus
        )
    }

    func testRejectsMismatchedOrMalformedContentRangeBeforeBodyDelivery() {
        for contentRange in [
            "bytes 0-15/64",
            "bytes 2-17/65",
            "bytes 2-18/64",
            "not-a-range",
            nil,
        ] {
            XCTAssertEqual(
                PlaybackHTTPRangeResponsePolicy.validate(
                    statusCode: 206,
                    contentRange: contentRange,
                    expectedLowerBound: 2,
                    expectedUpperBound: 17,
                    expectedTotalLength: 64
                ),
                .invalidContentRange
            )
        }
    }
}
