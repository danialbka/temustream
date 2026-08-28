import XCTest
@testable import StremioSkeletonCore

final class PlaybackBufferingPolicyTests: XCTestCase {
    func testRendererLeadExceedsResumeReserveWithoutBecomingLongTermBuffer() {
        XCTAssertGreaterThan(
            PlaybackBufferingPolicy.maximumRendererQueueLead,
            PlaybackBufferingPolicy.resumeReserve
        )
        XCTAssertLessThanOrEqual(
            PlaybackBufferingPolicy.maximumRendererQueueLead,
            1.5
        )
    }

    func testDecodedBacklogAndRendererCoverageMustReachFullResumeReserve() {
        let waiting = decision(
            rebuffering: true,
            videoEnd: 100.19,
            audioEnd: 101.20,
            decodedVideoBacklogEnd: 100.69
        )
        XCTAssertEqual(waiting.appliedRate, 0)
        XCTAssertTrue(waiting.isRebuffering)

        let ready = decision(
            rebuffering: true,
            videoEnd: 100.20,
            audioEnd: 101.20,
            decodedVideoBacklogEnd: 100.71
        )
        XCTAssertEqual(ready.appliedRate, 1)
        XCTAssertFalse(ready.isRebuffering)
    }

    func testPredecodedBackpressureEscapeCanResumeAtShortReserve() {
        let ready = decision(
            rebuffering: true,
            videoEnd: 100.20,
            audioEnd: 101.20,
            requiredResumeReserve:
                PlaybackBufferingPolicy.predecodedVideoResumeReserve,
            decodedVideoBacklogEnd: 100.21
        )
        XCTAssertEqual(ready.appliedRate, 1)
        XCTAssertFalse(ready.isRebuffering)
    }

    func testVideoDecodeLeadCoversMeasuredReorderWithoutPresentationRunway() {
        XCTAssertEqual(
            PlaybackBufferingPolicy.videoDecodeLead(
                maximumObservedLag: 0.1255
            ),
            0.126,
            accuracy: 0.000_001
        )
    }

    func testVideoDecodeLeadStillCoversUnusuallyDeepReorder() {
        XCTAssertEqual(
            PlaybackBufferingPolicy.videoDecodeLead(
                maximumObservedLag: 1.1255
            ),
            1.126,
            accuracy: 0.000_001
        )
    }

    func testSecondKeyframeCompletesVideoTimingCalibration() {
        XCTAssertFalse(PlaybackBufferingPolicy.videoTimingCalibrationReady(
            keyframeCount: 1,
            packetCount: 24,
            decodeSpan: 1,
            reservoirIsFull: false
        ))
        XCTAssertTrue(PlaybackBufferingPolicy.videoTimingCalibrationReady(
            keyframeCount: 2,
            packetCount: 25,
            decodeSpan: 1.001,
            reservoirIsFull: false
        ))
    }

    func testTimingCalibrationHasBoundedLongGOPFallbacks() {
        XCTAssertTrue(PlaybackBufferingPolicy.videoTimingCalibrationReady(
            keyframeCount: 1,
            packetCount: PlaybackBufferingPolicy.videoTimingCalibrationPacketLimit,
            decodeSpan: 1.5,
            reservoirIsFull: false
        ))
        XCTAssertTrue(PlaybackBufferingPolicy.videoTimingCalibrationReady(
            keyframeCount: 1,
            packetCount: 12,
            decodeSpan: 0.5,
            reservoirIsFull: true
        ))
    }

    func testReorderedFuturePTSDoesNotOverstateContiguousVideoCoverage() {
        let frame = 1.0 / 24.0
        var queueEnd = PlaybackBufferingPolicy.contiguousVideoQueueEnd(
            previousEnd: 0,
            presentationTime: 0,
            decodeTime: 0,
            duration: frame
        )
        queueEnd = PlaybackBufferingPolicy.contiguousVideoQueueEnd(
            previousEnd: queueEnd,
            presentationTime: 0.375,
            decodeTime: frame,
            duration: frame
        )

        XCTAssertEqual(queueEnd, frame, accuracy: 0.000_001)
        XCTAssertLessThan(queueEnd, 0.375)
    }

    func testInvalidDTSFallsBackToPresentationCoverage() {
        let queueEnd = PlaybackBufferingPolicy.contiguousVideoQueueEnd(
            previousEnd: 10,
            presentationTime: 10.5,
            decodeTime: .nan,
            duration: 0.04
        )

        XCTAssertEqual(queueEnd, 10.54, accuracy: 0.000_001)
    }

    func testSeekHoldsClockUntilCommonReserveIsReady() {
        let waiting = decision(
            rebuffering: true,
            videoEnd: 100.65,
            audioEnd: 101.20
        )
        XCTAssertEqual(waiting.appliedRate, 0)
        XCTAssertTrue(waiting.isRebuffering)

        let ready = decision(
            rebuffering: true,
            videoEnd: 100.75,
            audioEnd: 101.20
        )
        XCTAssertEqual(ready.appliedRate, 1)
        XCTAssertFalse(ready.isRebuffering)
    }

    func testRunningClockEntersRebufferingBeforeUnderflow() {
        let result = decision(
            rebuffering: false,
            videoEnd: 100.07,
            audioEnd: 100.50
        )
        XCTAssertEqual(result.appliedRate, 0)
        XCTAssertTrue(result.isRebuffering)
    }

    func testDecodedVideoBacklogKeepsRunningClockAlive() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: false,
            clock: 100,
            videoQueueEnd: 100.03,
            audioQueueEnd: 101,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            reachedEnd: false,
            decodedVideoBacklogEnd: 100.50
        )
        XCTAssertEqual(result.appliedRate, 1)
        XCTAssertFalse(result.isRebuffering)
    }

    func testDecodedVideoBacklogDoesNotHideAudioUnderflow() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: false,
            clock: 100,
            videoQueueEnd: 100.03,
            audioQueueEnd: 100.03,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            reachedEnd: false,
            decodedVideoBacklogEnd: 100.50
        )
        XCTAssertEqual(result.appliedRate, 0)
        XCTAssertTrue(result.isRebuffering)
    }

    func testDecodedVideoBacklogBehindClockCannotHideVideoUnderflow() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: false,
            clock: 100,
            videoQueueEnd: 100.03,
            audioQueueEnd: 101,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            reachedEnd: false,
            decodedVideoBacklogEnd: 99.90
        )
        XCTAssertEqual(result.appliedRate, 0)
        XCTAssertTrue(result.isRebuffering)
    }

    func testHysteresisDoesNotResumeOnSmallReserve() {
        let result = decision(
            rebuffering: true,
            videoEnd: 100.50,
            audioEnd: 100.60
        )
        XCTAssertEqual(result.appliedRate, 0)
        XCTAssertTrue(result.isRebuffering)
    }

    func testUserPauseAlwaysWins() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 0,
            isRebuffering: false,
            clock: 100,
            videoQueueEnd: 108,
            audioQueueEnd: 108,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            reachedEnd: false
        )
        XCTAssertEqual(result.appliedRate, 0)
        XCTAssertFalse(result.isRebuffering)
    }

    func testAudioOnlyUsesAudioReserve() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1.25,
            isRebuffering: true,
            clock: 10,
            videoQueueEnd: .nan,
            audioQueueEnd: 11,
            hasVideo: false,
            hasAudio: true,
            nominalFrameRate: 0,
            reachedEnd: false
        )
        XCTAssertEqual(result.appliedRate, 1.25)
        XCTAssertFalse(result.isRebuffering)
    }

    func testVideoOnlyUsesVideoReserve() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: true,
            clock: 10,
            videoQueueEnd: 11,
            audioQueueEnd: .nan,
            hasVideo: true,
            hasAudio: false,
            nominalFrameRate: 24,
            reachedEnd: false
        )
        XCTAssertEqual(result.appliedRate, 1)
        XCTAssertFalse(result.isRebuffering)
    }

    func testEndOfStreamDrainsQueuedTail() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: true,
            clock: 99.95,
            videoQueueEnd: 100,
            audioQueueEnd: 100,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            reachedEnd: true
        )
        XCTAssertEqual(result.appliedRate, 1)
        XCTAssertFalse(result.isRebuffering)
    }

    func testSeekPrerollGraceTemporarilyAdvancesLowReserveClock() {
        let result = PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: true,
            clock: 100,
            videoQueueEnd: 100.04,
            audioQueueEnd: 100.03,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            allowsLowReservePlayback: true,
            reachedEnd: false
        )
        XCTAssertEqual(result.appliedRate, 1)
        XCTAssertFalse(result.isRebuffering)
    }

    private func decision(
        rebuffering: Bool,
        videoEnd: TimeInterval,
        audioEnd: TimeInterval,
        requiredResumeReserve: TimeInterval = PlaybackBufferingPolicy.resumeReserve,
        decodedVideoBacklogEnd: TimeInterval? = nil
    ) -> PlaybackBufferingDecision {
        PlaybackBufferingPolicy.decision(
            desiredRate: 1,
            isRebuffering: rebuffering,
            clock: 100,
            videoQueueEnd: videoEnd,
            audioQueueEnd: audioEnd,
            hasVideo: true,
            hasAudio: true,
            nominalFrameRate: 24,
            reachedEnd: false,
            requiredResumeReserve: requiredResumeReserve,
            decodedVideoBacklogEnd: decodedVideoBacklogEnd
        )
    }
}
