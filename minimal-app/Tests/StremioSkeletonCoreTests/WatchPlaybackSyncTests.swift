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

    func testMaximumRemoteCounterDoesNotCrashNextLocalEvents() {
        var reconciler = WatchPlaybackReconciler(actorID: "alice")
        let remote = WatchPlaybackEvent(
            contentKey: "movie:1",
            kind: .play,
            position: 10,
            isPlaying: true,
            rate: 1,
            version: WatchPlaybackVersion(counter: .max, actorID: "bob"),
            sentAtMilliseconds: 1_000
        )
        _ = reconciler.reconcile(
            remote: remote,
            local: WatchLocalPlaybackSample(position: 10, isPlaying: true, rate: 1),
            nowMilliseconds: 1_000
        )

        let first = reconciler.makeLocalEvent(
            contentKey: "movie:1",
            kind: .pause,
            sample: WatchLocalPlaybackSample(position: 11, isPlaying: false, rate: 1),
            nowMilliseconds: 2_000
        )
        let second = reconciler.makeLocalEvent(
            contentKey: "movie:1",
            kind: .play,
            sample: WatchLocalPlaybackSample(position: 11, isPlaying: true, rate: 1),
            nowMilliseconds: 3_000
        )

        XCTAssertEqual(remote.version.counter, WatchPlaybackVersion.maximumPeerCounter)
        XCTAssertEqual(
            first.version.counter,
            WatchPlaybackVersion.maximumPeerCounter + 1
        )
        XCTAssertGreaterThan(first.version, remote.version)
        XCTAssertEqual(second.version, first.version)
    }

    func testWireCounterNormalizesToLeaveAnExactLocalSuccessor() throws {
        let wire = Data(
            #"{"counter":9223372036854775807,"actorID":"zulu"}"#.utf8
        )
        let remote = try JSONDecoder().decode(WatchPlaybackVersion.self, from: wire)
        var reconciler = WatchPlaybackReconciler(actorID: "aardvark")
        _ = reconciler.reconcile(
            remote: WatchPlaybackEvent(
                contentKey: "movie:1",
                kind: .play,
                position: 10,
                isPlaying: true,
                rate: 1,
                version: remote,
                sentAtMilliseconds: 1_000
            ),
            local: WatchLocalPlaybackSample(position: 10, isPlaying: true, rate: 1),
            nowMilliseconds: 1_000
        )

        let local = reconciler.makeLocalEvent(
            contentKey: "movie:1",
            kind: .pause,
            sample: WatchLocalPlaybackSample(position: 11, isPlaying: false, rate: 1),
            nowMilliseconds: 2_000
        )

        XCTAssertEqual(remote.counter, WatchPlaybackVersion.maximumPeerCounter)
        XCTAssertGreaterThan(local.version, remote)
        XCTAssertEqual(Double(local.version.counter), 9_007_199_254_740_991)
    }

    func testReservedLocalSuccessorSurvivesWireRoundTrip() throws {
        let remote = WatchPlaybackVersion(
            counter: .max,
            actorID: "zulu"
        )
        var reconciler = WatchPlaybackReconciler(actorID: "aardvark")
        _ = reconciler.reconcile(
            remote: WatchPlaybackEvent(
                contentKey: "movie:1",
                kind: .play,
                position: 10,
                isPlaying: true,
                rate: 1,
                version: remote,
                sentAtMilliseconds: 1_000
            ),
            local: WatchLocalPlaybackSample(position: 10, isPlaying: true, rate: 1),
            nowMilliseconds: 1_000
        )
        let local = reconciler.makeLocalEvent(
            contentKey: "movie:1",
            kind: .pause,
            sample: WatchLocalPlaybackSample(position: 11, isPlaying: false, rate: 1),
            nowMilliseconds: 2_000
        )

        let encoded = try JSONEncoder().encode(local)
        let decoded = try JSONDecoder().decode(WatchPlaybackEvent.self, from: encoded)

        XCTAssertEqual(decoded.version, local.version)
        XCTAssertGreaterThan(decoded.version, remote)
    }

    func testProjectionClampsExtremePeerTimestampsWithoutIntegerOverflow() throws {
        let remote = WatchPlaybackEvent(
            contentKey: "movie:1",
            kind: .heartbeat,
            position: 12,
            isPlaying: true,
            rate: 1,
            version: WatchPlaybackVersion(counter: 1, actorID: "bob"),
            sentAtMilliseconds: .min
        )
        let encoded = try JSONEncoder().encode(remote)
        let decoded = try JSONDecoder().decode(WatchPlaybackEvent.self, from: encoded)

        XCTAssertEqual(decoded.projectedPosition(at: 0), 42, accuracy: 0.001)

        let future = WatchPlaybackEvent(
            contentKey: "movie:1",
            kind: .heartbeat,
            position: 12,
            isPlaying: true,
            rate: 1,
            version: WatchPlaybackVersion(counter: 2, actorID: "bob"),
            sentAtMilliseconds: .max
        )
        XCTAssertEqual(future.projectedPosition(at: 0), 12, accuracy: 0.001)
    }

    func testWirePlaybackEventAppliesInitializerRateBounds() throws {
        let wire = Data(
            """
            {
              "eventID":"00000000-0000-0000-0000-000000000001",
              "contentKey":"movie:wire",
              "kind":"heartbeat",
              "position":12,
              "isPlaying":true,
              "rate":1e308,
              "version":{"counter":1,"actorID":"peer"},
              "sentAtMilliseconds":0
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(WatchPlaybackEvent.self, from: wire)

        XCTAssertEqual(event.rate, 4)
        XCTAssertEqual(event.projectedPosition(at: 30_000), 132, accuracy: 0.001)
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
