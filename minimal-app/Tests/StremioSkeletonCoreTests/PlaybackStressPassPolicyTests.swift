import XCTest
@testable import StremioSkeletonCore

final class PlaybackStressPassPolicyTests: XCTestCase {
    func testRealTimeRatioRejectsFastClockAsWellAsSlowClock() {
        XCTAssertTrue(PlaybackStressPassPolicy.realTimeRatioIsPlausible(1.02))
        XCTAssertFalse(PlaybackStressPassPolicy.realTimeRatioIsPlausible(0.90))
        XCTAssertFalse(PlaybackStressPassPolicy.realTimeRatioIsPlausible(2.00))
    }

    func testInteractionDropBudgetIsFinite() {
        XCTAssertTrue(
            PlaybackStressPassPolicy.interactionDropsAreWithinBudget(
                droppedFrames: 10,
                seekAttempts: 5,
                pauseResumeAttempts: 5
            )
        )
        XCTAssertFalse(
            PlaybackStressPassPolicy.interactionDropsAreWithinBudget(
                droppedFrames: 11,
                seekAttempts: 5,
                pauseResumeAttempts: 5
            )
        )
    }

    func testVideoWithoutPresentationMetricsIsExplicitlyUnsupported() {
        XCTAssertEqual(
            PlaybackStressPassPolicy.presentedCadenceStatus(
                hasVideo: true,
                nominalFPS: 24,
                presentedFPS: nil
            ),
            .unsupported
        )
    }

    func testPresentedCadenceRejectsFrozenOrImplausiblyFastOutput() {
        XCTAssertEqual(
            PlaybackStressPassPolicy.presentedCadenceStatus(
                hasVideo: true,
                nominalFPS: 24,
                presentedFPS: 23.8
            ),
            .verified
        )
        XCTAssertEqual(
            PlaybackStressPassPolicy.presentedCadenceStatus(
                hasVideo: true,
                nominalFPS: 24,
                presentedFPS: 2
            ),
            .implausible
        )
        XCTAssertEqual(
            PlaybackStressPassPolicy.presentedCadenceStatus(
                hasVideo: true,
                nominalFPS: 24,
                presentedFPS: 48
            ),
            .implausible
        )
    }
}
