import XCTest
@testable import StremioSkeletonCore

final class PlaybackSeekTransitionPolicyTests: XCTestCase {
    func testCompletePrerollSamplesStayHidden() {
        XCTAssertTrue(
            PlaybackSeekTransitionPolicy.sampleIsEntirelyBeforeTarget(
                presentationTime: 8,
                duration: 1,
                targetTime: 10
            )
        )
        XCTAssertTrue(
            PlaybackSeekTransitionPolicy.sampleIsEntirelyBeforeTarget(
                presentationTime: 9,
                duration: 1,
                targetTime: 10
            )
        )
    }

    func testSampleCoveringTargetIsPresentable() {
        XCTAssertFalse(
            PlaybackSeekTransitionPolicy.sampleIsEntirelyBeforeTarget(
                presentationTime: 9.98,
                duration: 0.04,
                targetTime: 10
            )
        )
        XCTAssertFalse(
            PlaybackSeekTransitionPolicy.sampleIsEntirelyBeforeTarget(
                presentationTime: 10,
                duration: 0.04,
                targetTime: 10
            )
        )
    }

    func testUnknownDurationUsesPresentationTimestamp() {
        XCTAssertTrue(
            PlaybackSeekTransitionPolicy.sampleIsEntirelyBeforeTarget(
                presentationTime: 9.9,
                duration: .nan,
                targetTime: 10
            )
        )
        XCTAssertFalse(
            PlaybackSeekTransitionPolicy.sampleIsEntirelyBeforeTarget(
                presentationTime: 10,
                duration: .nan,
                targetTime: 10
            )
        )
    }

    func testPostFlushDecoderWaitsForRandomAccessPoint() {
        XCTAssertTrue(
            PlaybackSeekTransitionPolicy.shouldDiscardVideoBeforeRandomAccessPoint(
                isKeyframe: false,
                isWaitingForRandomAccessPoint: true
            )
        )
        XCTAssertFalse(
            PlaybackSeekTransitionPolicy.shouldDiscardVideoBeforeRandomAccessPoint(
                isKeyframe: true,
                isWaitingForRandomAccessPoint: true
            )
        )
        XCTAssertFalse(
            PlaybackSeekTransitionPolicy.shouldDiscardVideoBeforeRandomAccessPoint(
                isKeyframe: false,
                isWaitingForRandomAccessPoint: false
            )
        )
    }
}
