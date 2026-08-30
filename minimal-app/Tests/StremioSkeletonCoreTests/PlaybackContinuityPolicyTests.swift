import XCTest
@testable import StremioSkeletonCore

final class PlaybackContinuityPolicyTests: XCTestCase {
    func testBackFifteenUsesPendingInitialResumeInsteadOfZeroDecoderClock() {
        XCTAssertEqual(
            PlaybackContinuityPolicy.relativeSeekTarget(
                by: -15,
                currentPosition: 0,
                pendingPosition: nil,
                initialResumePosition: 600,
                duration: 1_200
            ),
            585
        )
    }

    func testRelativeSeekUsesInFlightTargetBeforeInitialResumeAnchor() {
        XCTAssertEqual(
            PlaybackContinuityPolicy.relativeSeekTarget(
                by: -15,
                currentPosition: 0,
                pendingPosition: 585,
                initialResumePosition: 600,
                duration: 1_200
            ),
            570
        )
    }

    func testRelativeSeekUsesCurrentClockAfterResumeSettles() {
        XCTAssertEqual(
            PlaybackContinuityPolicy.relativeSeekTarget(
                by: 15,
                currentPosition: 585,
                pendingPosition: nil,
                initialResumePosition: nil,
                duration: 1_200
            ),
            600
        )
    }

    func testRelativeSeekClampsAtMediaBounds() {
        XCTAssertEqual(
            PlaybackContinuityPolicy.relativeSeekTarget(
                by: -15,
                currentPosition: 5,
                pendingPosition: nil,
                initialResumePosition: nil,
                duration: 100
            ),
            0
        )
        XCTAssertEqual(
            PlaybackContinuityPolicy.relativeSeekTarget(
                by: 15,
                currentPosition: 95,
                pendingPosition: nil,
                initialResumePosition: nil,
                duration: 100
            ),
            99.75
        )
    }

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
