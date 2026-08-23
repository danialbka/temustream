import XCTest
@testable import StremioSkeletonCore

final class WatchPlaybackSyncTests: XCTestCase {
    func testVoiceStartsOffAndCannotToggleOutsideConnectedRoom() {
        XCTAssertFalse(WatchVoiceControlState.off.isCapturing)
        XCTAssertEqual(WatchVoiceControlState.off.controlText, "Muted")
        XCTAssertEqual(WatchVoiceControlState.live.controlText, "Live")
        XCTAssertEqual(WatchVoiceControlState.denied.statusText, "Microphone permission denied")
        XCTAssertFalse(WatchVoiceControlState.off.canToggle(roomConnected: false))
        XCTAssertTrue(WatchVoiceControlState.off.canToggle(roomConnected: true))
        XCTAssertFalse(WatchVoiceControlState.denied.canToggle(roomConnected: true))
    }

    func testRemoteVersionOrdersByCounterThenActor() {
        XCTAssertLessThan(
            WatchPlaybackVersion(counter: 4, actorID: "alice"),
            WatchPlaybackVersion(counter: 4, actorID: "bob")
        )
        XCTAssertLessThan(
            WatchPlaybackVersion(counter: 4, actorID: "zebra"),
            WatchPlaybackVersion(counter: 5, actorID: "alice")
        )
    }

    func testObservingHighRemoteCounterAdvancesNextLocalEvent() {
        var reconciler = WatchPlaybackReconciler(actorID: "alice")
        let remote = WatchPlaybackEvent(
            contentKey: "movie:1",
            kind: .play,
            position: 10,
            isPlaying: true,
            rate: 1,
            version: WatchPlaybackVersion(counter: 91, actorID: "bob"),
            sentAtMilliseconds: 1_000
        )
        _ = reconciler.reconcile(
            remote: remote,
            local: WatchLocalPlaybackSample(position: 10, isPlaying: true, rate: 1),
            nowMilliseconds: 1_000
        )
        let next = reconciler.makeLocalEvent(
            contentKey: "movie:1",
            kind: .pause,
            sample: WatchLocalPlaybackSample(position: 11, isPlaying: false, rate: 1),
            nowMilliseconds: 2_000
        )
        XCTAssertEqual(next.version.counter, 92)
    }

    func testStaleEventIsRejectedAfterNewerEvent() {
        var reconciler = WatchPlaybackReconciler(actorID: "alice")
        let sample = WatchLocalPlaybackSample(position: 5, isPlaying: false, rate: 1)
        let newer = WatchPlaybackEvent(
            contentKey: "movie:1", kind: .seek, position: 20, isPlaying: false, rate: 1,
            version: WatchPlaybackVersion(counter: 8, actorID: "bob"), sentAtMilliseconds: 1_000
        )
        let stale = WatchPlaybackEvent(
            contentKey: "movie:1", kind: .seek, position: 2, isPlaying: false, rate: 1,
            version: WatchPlaybackVersion(counter: 7, actorID: "bob"), sentAtMilliseconds: 1_100
        )
        XCTAssertNotNil(reconciler.reconcile(remote: newer, local: sample, nowMilliseconds: 1_000))
        XCTAssertNil(reconciler.reconcile(remote: stale, local: sample, nowMilliseconds: 1_100))
    }

    func testPlayingEventProjectsTransportTimeAndSeeksLargeDrift() {
        var reconciler = WatchPlaybackReconciler(actorID: "alice")
        let remote = WatchPlaybackEvent(
            contentKey: "movie:1", kind: .heartbeat, position: 30, isPlaying: true, rate: 1,
            version: WatchPlaybackVersion(counter: 1, actorID: "bob"), sentAtMilliseconds: 1_000
        )
        let adjustment = reconciler.reconcile(
            remote: remote,
            local: WatchLocalPlaybackSample(position: 29, isPlaying: true, rate: 1),
            nowMilliseconds: 2_000
        )
        XCTAssertNotNil(adjustment?.targetPosition)
        XCTAssertEqual(adjustment!.targetPosition!, 31, accuracy: 0.001)
    }

    func testSmallPlayingDriftUsesTemporaryRateCorrection() {
        var reconciler = WatchPlaybackReconciler(actorID: "alice")
        let remote = WatchPlaybackEvent(
            contentKey: "movie:1", kind: .heartbeat, position: 10.3, isPlaying: true, rate: 1,
            version: WatchPlaybackVersion(counter: 1, actorID: "bob"), sentAtMilliseconds: 1_000
        )
        let adjustment = reconciler.reconcile(
            remote: remote,
            local: WatchLocalPlaybackSample(position: 10, isPlaying: true, rate: 1),
            nowMilliseconds: 1_000
        )
        XCTAssertNotNil(adjustment?.temporaryRate)
        XCTAssertEqual(adjustment!.temporaryRate!, 1.03, accuracy: 0.001)
        XCTAssertEqual(adjustment!.temporaryRateDuration, 0.4, accuracy: 0.001)
    }
}
