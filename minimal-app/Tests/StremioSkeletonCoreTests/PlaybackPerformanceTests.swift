import Foundation
import XCTest
@testable import StremioSkeletonCore

@MainActor
final class PlaybackPerformanceTests: XCTestCase {
    func testBoundedCacheExpiresEntriesAndEvictsLeastRecentlyUsed() {
        let base = Date(timeIntervalSince1970: 1_000)
        var cache = BoundedCache<String, Int>(capacity: 2, timeToLive: 10)
        cache.insert(1, forKey: "one", now: base)
        cache.insert(2, forKey: "two", now: base)
        XCTAssertEqual(cache.value(forKey: "one", now: base.addingTimeInterval(1)), 1)

        cache.insert(3, forKey: "three", now: base.addingTimeInterval(2))
        XCTAssertNil(cache.value(forKey: "two", now: base.addingTimeInterval(2)))
        XCTAssertEqual(cache.value(forKey: "one", now: base.addingTimeInterval(2)), 1)
        XCTAssertNil(cache.value(forKey: "one", now: base.addingTimeInterval(11)))
    }

    func testNearViewportPolicyIsBoundedAtBothEdges() {
        XCTAssertEqual(
            NearViewportPrefetchPolicy.indices(
                visibleRange: 0..<2,
                itemCount: 10,
                lookBehind: 2,
                lookAhead: 3
            ),
            [0, 1, 2, 3, 4]
        )
        XCTAssertEqual(
            NearViewportPrefetchPolicy.indices(
                visibleRange: 8..<10,
                itemCount: 10,
                lookBehind: 2,
                lookAhead: 3
            ),
            [6, 7, 8, 9]
        )
    }

    func testPerformanceMilestonesKeepFirstObservationAndBoundHistory() throws {
        let recorder = PerformanceMilestoneRecorder(capacity: 1)
        let first = recorder.begin(flow: .playback, identity: "movie:one", at: 10)
        let initialElapsed = try XCTUnwrap(
            recorder.mark(.streamResolved, for: first, at: 10.2)
        )
        let repeatedElapsed = try XCTUnwrap(
            recorder.mark(.streamResolved, for: first, at: 11)
        )
        XCTAssertEqual(initialElapsed, 200, accuracy: 0.001)
        XCTAssertEqual(repeatedElapsed, 200, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(recorder.snapshot(for: first)?.elapsedMilliseconds(to: .streamResolved)),
            200,
            accuracy: 0.001
        )

        _ = recorder.begin(flow: .detail, identity: "movie:two", at: 12)
        XCTAssertNil(recorder.snapshot(for: first))
        XCTAssertEqual(recorder.recentSnapshots().count, 1)
    }

    func testNativePlaybackTrackerGradesStablePlaybackAfterWarmup() throws {
        var tracker = NativePlaybackPerformanceTracker(
            startedAt: 10,
            initialPosition: 0
        )
        _ = tracker.observe(
            at: 11,
            position: 0,
            isPlaying: true,
            bufferSeconds: 6,
            stalls: 0,
            droppedVideoFrames: 0,
            observedBitrate: 8_000_000,
            indicatedBitrate: 10_000_000
        )
        let snapshot = tracker.observe(
            at: 21,
            position: 10,
            isPlaying: true,
            bufferSeconds: 12,
            stalls: 0,
            droppedVideoFrames: 0,
            observedBitrate: 8_000_000,
            indicatedBitrate: 10_000_000
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.startupMilliseconds), 1_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.clockRatio), 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.health, .good)
        XCTAssertTrue(snapshot.logDescription.contains("health=good"))
    }

    func testNativePlaybackTrackerRetainsWorstCounters() {
        var tracker = NativePlaybackPerformanceTracker(
            startedAt: 20,
            initialPosition: 120
        )
        _ = tracker.observe(
            at: 20.5,
            position: 120,
            isPlaying: true,
            bufferSeconds: 4,
            stalls: 1,
            droppedVideoFrames: 3,
            observedBitrate: nil,
            indicatedBitrate: nil
        )
        let snapshot = tracker.observe(
            at: 30.5,
            position: 130,
            isPlaying: true,
            bufferSeconds: 8,
            stalls: 0,
            droppedVideoFrames: 0,
            observedBitrate: nil,
            indicatedBitrate: nil
        )

        XCTAssertEqual(snapshot.stalls, 1)
        XCTAssertEqual(snapshot.droppedVideoFrames, 3)
        XCTAssertEqual(snapshot.health, .attention)
    }

    func testInFlightGateCoalescesIdenticalRequests() async throws {
        let gate = InFlightRequestGate<String, Int>()
        let counter = InvocationCounter()
        async let first = gate.run(key: "detail") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(80))
            return 42
        }
        async let second = gate.run(key: "detail") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(80))
            return 99
        }

        let values = try await [first, second]
        let invocationCount = await counter.value
        let activeRequestCount = await gate.activeRequestCount
        XCTAssertEqual(values[0], values[1])
        XCTAssertTrue(values[0] == 42 || values[0] == 99)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(activeRequestCount, 0)
    }

    func testCancelledRequestCannotClearReplacementForSameKey() async throws {
        let gate = InFlightRequestGate<String, Int>()
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let secondStarted = AsyncSignal()
        let releaseSecond = AsyncSignal()

        let first = Task {
            try await gate.run(key: "detail") {
                await firstStarted.signal()
                await releaseFirst.wait()
                try Task.checkCancellation()
                return 1
            }
        }
        await firstStarted.wait()
        await gate.cancel(key: "detail")

        let second = Task {
            try await gate.run(key: "detail") {
                await secondStarted.signal()
                await releaseSecond.wait()
                return 2
            }
        }
        await secondStarted.wait()
        await releaseFirst.signal()
        _ = try? await first.value

        let joined = Task {
            try await gate.run(key: "detail") { 3 }
        }
        // Give the joined caller time to reach the actor while the replacement
        // is deliberately held open. It must coalesce onto that replacement.
        try await Task.sleep(for: .milliseconds(20))
        await releaseSecond.signal()
        let values = try await [second.value, joined.value]
        let activeRequestCount = await gate.activeRequestCount

        XCTAssertEqual(values, [2, 2])
        XCTAssertEqual(activeRequestCount, 0)
    }

}

private actor InvocationCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor AsyncSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        if isSignalled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
