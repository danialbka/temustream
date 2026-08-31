import XCTest
@testable import StremioSkeletonCore

final class PlaybackContinuityPolicyTests: XCTestCase {
    func testTimelinePositionClampsAtKnownMediaBounds() {
        XCTAssertEqual(
            PlaybackContinuityPolicy.clampedTimelinePosition(-1, duration: 60),
            0
        )
        XCTAssertEqual(
            PlaybackContinuityPolicy.clampedTimelinePosition(42, duration: 60),
            42
        )
        XCTAssertEqual(
            PlaybackContinuityPolicy.clampedTimelinePosition(72, duration: 60),
            60
        )
    }

    func testTimelinePositionPreservesFiniteClockWhenDurationIsUnknown() {
        XCTAssertEqual(
            PlaybackContinuityPolicy.clampedTimelinePosition(72, duration: 0),
            72
        )
        XCTAssertEqual(
            PlaybackContinuityPolicy.clampedTimelinePosition(72, duration: .nan),
            72
        )
        XCTAssertEqual(
            PlaybackContinuityPolicy.clampedTimelinePosition(.infinity, duration: 60),
            0
        )
    }

    func testTerminalClockContinuesTailDrainBeforeKnownDurationBoundary() {
        let decision = PlaybackContinuityPolicy.terminalClockDecision(
            sampledPosition: 59,
            duration: 60,
            continuingRate: 1
        )

        XCTAssertFalse(decision.shouldFinish)
        XCTAssertEqual(decision.position, 59)
        XCTAssertEqual(decision.desiredRate, 1)
        XCTAssertEqual(decision.appliedRate, 1)
    }

    func testTerminalClockStopsAtExactKnownDurationBoundary() {
        for sampledPosition in [59.95, 72] {
            let decision = PlaybackContinuityPolicy.terminalClockDecision(
                sampledPosition: sampledPosition,
                duration: 60,
                continuingRate: 1
            )

            XCTAssertTrue(decision.shouldFinish)
            XCTAssertEqual(decision.position, 60)
            XCTAssertEqual(decision.desiredRate, 0)
            XCTAssertEqual(decision.appliedRate, 0)
        }
    }

    func testTerminalClockStopsAtSampledPositionWhenDurationIsUnknown() {
        let decision = PlaybackContinuityPolicy.terminalClockDecision(
            sampledPosition: 72,
            duration: 0,
            continuingRate: 1
        )

        XCTAssertTrue(decision.shouldFinish)
        XCTAssertEqual(decision.position, 72)
        XCTAssertEqual(decision.desiredRate, 0)
        XCTAssertEqual(decision.appliedRate, 0)
    }

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
