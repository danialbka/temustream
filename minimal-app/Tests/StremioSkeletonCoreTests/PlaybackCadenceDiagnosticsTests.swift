import XCTest
@testable import StremioSkeletonCore

final class PlaybackCadenceDiagnosticsTests: XCTestCase {
    func testTimestampTrackerReportsStableCadence() throws {
        var tracker = PlaybackTimestampCadenceTracker(
            nominalFrameRate: 24,
            capacity: 8
        )
        for frame in 0..<9 {
            tracker.observe(presentationTime: Double(frame) / 24)
        }

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.observedFrames, 9)
        XCTAssertEqual(snapshot.windowTransitions, 8)
        XCTAssertEqual(snapshot.backwardTransitions, 0)
        XCTAssertEqual(snapshot.duplicateTransitions, 0)
        XCTAssertEqual(snapshot.irregularForwardTransitions, 0)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.medianForwardIntervalMilliseconds),
            1_000 / 24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.p95ForwardIntervalMilliseconds),
            1_000 / 24,
            accuracy: 0.001
        )
    }

    func testTimestampTrackerRetainsReorderAndGapEvidence() throws {
        var tracker = PlaybackTimestampCadenceTracker(
            nominalFrameRate: 25,
            capacity: 5
        )
        [0.00, 0.08, 0.04, 0.04, 0.12, 0.24].forEach {
            tracker.observe(presentationTime: $0)
        }

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.windowTransitions, 5)
        XCTAssertEqual(snapshot.backwardTransitions, 1)
        XCTAssertEqual(snapshot.duplicateTransitions, 1)
        XCTAssertEqual(snapshot.irregularForwardTransitions, 3)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.maximumForwardIntervalMilliseconds),
            120,
            accuracy: 0.001
        )
    }

    func testTimestampTrackerResetExcludesSeekDiscontinuity() {
        var tracker = PlaybackTimestampCadenceTracker(nominalFrameRate: 30)
        tracker.observe(presentationTime: 1)
        tracker.observe(presentationTime: 1 + 1 / 30)
        tracker.reset()
        tracker.observe(presentationTime: 400)
        tracker.observe(presentationTime: 400 + 1 / 30)

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.observedFrames, 2)
        XCTAssertEqual(snapshot.windowTransitions, 1)
        XCTAssertEqual(snapshot.backwardTransitions, 0)
        XCTAssertEqual(snapshot.irregularForwardTransitions, 0)
    }

    func testRendererCadenceUsesDisplayedFramesAndDelayDelta() {
        let previous = PlaybackRendererCumulativeMetrics(
            totalFrames: 100,
            droppedFrames: 2,
            corruptedFrames: 1,
            accumulatedFrameDelay: 0.20
        )
        let current = PlaybackRendererCumulativeMetrics(
            totalFrames: 150,
            droppedFrames: 4,
            corruptedFrames: 1,
            accumulatedFrameDelay: 0.44
        )

        let snapshot = PlaybackRendererCadenceDiagnostics.interval(
            previous: previous,
            current: current,
            elapsed: 2
        )
        XCTAssertEqual(snapshot.intervalFrames, 50)
        XCTAssertEqual(snapshot.intervalDroppedFrames, 2)
        XCTAssertEqual(snapshot.displayedFramesPerSecond, 24, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageFrameDelayMilliseconds, 5, accuracy: 0.001)
        XCTAssertFalse(snapshot.countersReset)
    }

    func testRendererCadenceHandlesFlushCounterReset() {
        let previous = PlaybackRendererCumulativeMetrics(
            totalFrames: 500,
            droppedFrames: 8,
            corruptedFrames: 2,
            accumulatedFrameDelay: 1.5
        )
        let current = PlaybackRendererCumulativeMetrics(
            totalFrames: 24,
            droppedFrames: 1,
            corruptedFrames: 0,
            accumulatedFrameDelay: 0.12
        )

        let snapshot = PlaybackRendererCadenceDiagnostics.interval(
            previous: previous,
            current: current,
            elapsed: 1
        )
        XCTAssertTrue(snapshot.countersReset)
        XCTAssertEqual(snapshot.intervalFrames, 24)
        XCTAssertEqual(snapshot.displayedFramesPerSecond, 23, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageFrameDelayMilliseconds, 120 / 23, accuracy: 0.001)
    }
}
