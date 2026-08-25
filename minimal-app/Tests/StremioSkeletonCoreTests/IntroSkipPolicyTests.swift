import XCTest
@testable import StremioSkeletonCore

final class IntroSkipPolicyTests: XCTestCase {
    func testDecodesTopLevelAndBehaviorHintFormats() throws {
        let response = try JSONDecoder().decode(
            StreamResponse.self,
            from: Data(
                #"""
                {
                  "streams": [
                    {
                      "url": "https://example.com/episode.mp4",
                      "skipSegments": [
                        {"start": 5, "end": 87.25, "type": "intro"}
                      ]
                    },
                    {
                      "url": "https://example.com/alternate.mp4",
                      "behaviorHints": {
                        "skipSegments": [
                          {
                            "startTime": 7,
                            "endTime": 91.5,
                            "type": "intro",
                            "confidence": "0.98",
                            "sampleSize": 12
                          }
                        ]
                      }
                    }
                  ]
                }
                """#.utf8
            )
        )

        XCTAssertEqual(response.streams[0].introSkipSegment?.end, 87.25)
        XCTAssertEqual(response.streams[1].introSkipSegment?.start, 7)
        XCTAssertEqual(response.streams[1].introSkipSegment?.confidence, 0.98)
        XCTAssertEqual(response.streams[1].introSkipSegment?.sampleSize, 12)
    }

    func testUsesExactValidatedEndBoundary() throws {
        let segment = PlaybackSkipSegment(
            start: 8.5,
            end: 93.125,
            type: "intro",
            confidence: 0.97,
            sampleSize: 8
        )

        XCTAssertTrue(IntroSkipPolicy.shouldOfferSkip(for: segment, position: 8.5))
        XCTAssertEqual(try XCTUnwrap(IntroSkipPolicy.targetPosition(for: segment)), 93.125)
        XCTAssertFalse(IntroSkipPolicy.shouldOfferSkip(for: segment, position: 93))
    }

    func testRejectsGuessesAndLowConfidenceRanges() {
        XCTAssertNil(IntroSkipPolicy.bestValidatedSegment(from: []))
        XCTAssertNil(
            IntroSkipPolicy.bestValidatedSegment(
                from: [
                    PlaybackSkipSegment(
                        start: 0,
                        end: 90,
                        type: "intro",
                        confidence: 0.52
                    ),
                ]
            )
        )
        XCTAssertNil(
            IntroSkipPolicy.bestValidatedSegment(
                from: [
                    PlaybackSkipSegment(start: 20, end: 10, type: "intro"),
                ]
            )
        )
    }
}
