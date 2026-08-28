import XCTest
@testable import StremioSkeletonCore

final class PlaybackBufferingPolicyTests: XCTestCase {
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
        audioEnd: TimeInterval
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
            reachedEnd: false
        )
    }
}
