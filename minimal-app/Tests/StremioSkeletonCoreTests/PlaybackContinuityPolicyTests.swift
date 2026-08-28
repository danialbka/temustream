import XCTest
@testable import StremioSkeletonCore

final class PlaybackContinuityPolicyTests: XCTestCase {
    func testPiPForegroundReturnDoesNotRestartOrdinaryPlayback() {
        XCTAssertFalse(
            PlaybackContinuityPolicy.shouldResumeAfterCancelledScrub(
                wasScrubbing: false,
                wantsPlayback: true,
                isPreparing: false
            )
        )
    }

    func testForegroundReturnResumesOnlyAScrubCancelledByTheSystemOverlay() {
        XCTAssertTrue(
            PlaybackContinuityPolicy.shouldResumeAfterCancelledScrub(
                wasScrubbing: true,
                wantsPlayback: true,
                isPreparing: false
            )
        )
        XCTAssertFalse(
            PlaybackContinuityPolicy.shouldResumeAfterCancelledScrub(
                wasScrubbing: true,
                wantsPlayback: false,
                isPreparing: false
            )
        )
    }

    func testEquivalentPlaybackRateDoesNotReanchorClock() {
        XCTAssertFalse(
            PlaybackContinuityPolicy.requiresClockRateChange(
                currentRate: 1,
                requestedRate: 1
            )
        )
        XCTAssertTrue(
            PlaybackContinuityPolicy.requiresClockRateChange(
                currentRate: 0,
                requestedRate: 1
            )
        )
    }
}
