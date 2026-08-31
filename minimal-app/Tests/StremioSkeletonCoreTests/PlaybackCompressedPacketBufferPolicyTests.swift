import XCTest
@testable import StremioSkeletonCore

final class PlaybackCompressedPacketBufferPolicyTests: XCTestCase {
    func testCinemaWidthReceives4KClassCompressedReserve() {
        let limits = PlaybackCompressedPacketBufferPolicy.limits(width: 3_840, height: 1_600)

        XCTAssertEqual(limits.maximumBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumDuration, 10)
        XCTAssertEqual(limits.maximumPacketCount, 8_192)
    }

    func test1080pReserveMatchesFormerPlayerBuffer() {
        let limits = PlaybackCompressedPacketBufferPolicy.limits(width: 1_920, height: 1_080)

        XCTAssertEqual(limits.maximumBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumDuration, 8)
    }

    func testSmallerVideoUsesBoundedMobileReserve() {
        let limits = PlaybackCompressedPacketBufferPolicy.limits(width: 1_280, height: 720)

        XCTAssertEqual(limits.maximumBytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumDuration, 8)
    }

    func testAnyIndependentLimitStopsReadAhead() {
        let limits = PlaybackCompressedPacketBufferPolicy.limits(width: 3_840, height: 2_160)

        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.isFull(
            byteCount: limits.maximumBytes,
            packetCount: 1,
            bufferedDuration: 1,
            limits: limits
        ))
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.isFull(
            byteCount: 1,
            packetCount: limits.maximumPacketCount,
            bufferedDuration: 1,
            limits: limits
        ))
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.isFull(
            byteCount: 1,
            packetCount: 1,
            bufferedDuration: limits.maximumDuration,
            limits: limits
        ))
        XCTAssertFalse(PlaybackCompressedPacketBufferPolicy.isFull(
            byteCount: limits.maximumBytes - 1,
            packetCount: limits.maximumPacketCount - 1,
            bufferedDuration: limits.maximumDuration - 0.001,
            limits: limits
        ))
    }

    func testRemotePlaybackWaitsForThreeSecondCompressedPreroll() {
        XCTAssertFalse(PlaybackCompressedPacketBufferPolicy.hasRemotePreroll(
            bufferedDuration: 2.999,
            isFull: false
        ))
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.hasRemotePreroll(
            bufferedDuration: 3,
            isFull: false
        ))
    }

    func testAFullReservoirCanStartEvenBelowDurationTarget() {
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.hasRemotePreroll(
            bufferedDuration: 0.5,
            isFull: true
        ))
    }

    func testLargeRemoteSourceWaitsForBoundedReservoirToFill() {
        XCTAssertFalse(PlaybackCompressedPacketBufferPolicy.hasRemotePreroll(
            bufferedDuration: 9.9,
            isFull: false,
            requiresFullBuffer: true
        ))
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.hasRemotePreroll(
            bufferedDuration: 4,
            isFull: true,
            requiresFullBuffer: true
        ))
    }

    func testReadAheadWaitsForLowWatermarkThenRefillsInOneBurst() {
        let limits = PlaybackCompressedPacketBufferPolicy.limits(
            width: 3_840,
            height: 1_600
        )
        XCTAssertFalse(PlaybackCompressedPacketBufferPolicy.shouldRefill(
            isRefilling: false,
            byteCount: 56 * 1_024 * 1_024,
            packetCount: 300,
            bufferedDuration: 8.75,
            limits: limits
        ))
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.shouldRefill(
            isRefilling: false,
            byteCount: 48 * 1_024 * 1_024,
            packetCount: 250,
            bufferedDuration: 7.5,
            limits: limits
        ))
        XCTAssertTrue(PlaybackCompressedPacketBufferPolicy.shouldRefill(
            isRefilling: true,
            byteCount: 48 * 1_024 * 1_024,
            packetCount: 300,
            bufferedDuration: 7.5,
            limits: limits
        ))
        XCTAssertFalse(PlaybackCompressedPacketBufferPolicy.shouldRefill(
            isRefilling: true,
            byteCount: limits.maximumBytes,
            packetCount: 400,
            bufferedDuration: 8,
            limits: limits
        ))
    }

    func testHealthyFutureSubtitleIsRetainedWhileReservoirHasHeadroom() {
        let limits = PlaybackCompressedPacketBufferLimits(
            maximumBytes: 1_024,
            maximumDuration: 10,
            maximumPacketCount: 10
        )

        XCTAssertEqual(
            PlaybackCompressedPacketBufferPolicy
                .blockingFutureSubtitleEvictionIndices(
                    packets: [
                        PlaybackCompressedPacketFootprint(
                            byteCount: 20,
                            timelineStart: 60,
                            timelineEnd: 60,
                            isSubtitle: true
                        ),
                    ],
                    subtitleReadyThrough: 12,
                    limits: limits
                ),
            []
        )
    }

    func testFarthestFutureSubtitleIsEvictedOnlyWhenItsSpanBlocksRefill() {
        let limits = PlaybackCompressedPacketBufferLimits(
            maximumBytes: 1_024,
            maximumDuration: 10,
            maximumPacketCount: 10
        )

        XCTAssertEqual(
            PlaybackCompressedPacketBufferPolicy
                .blockingFutureSubtitleEvictionIndices(
                    packets: [
                        PlaybackCompressedPacketFootprint(
                            byteCount: 20,
                            timelineStart: 60,
                            timelineEnd: 60,
                            isSubtitle: true
                        ),
                        PlaybackCompressedPacketFootprint(
                            byteCount: 20,
                            timelineStart: 70,
                            timelineEnd: 70,
                            isSubtitle: true
                        ),
                    ],
                    subtitleReadyThrough: 12,
                    limits: limits
                ),
            [1]
        )
    }

    func testFutureSubtitlesArePreservedWhenAudioVideoRemainIndependentlyFull() {
        let limits = PlaybackCompressedPacketBufferLimits(
            maximumBytes: 1_024,
            maximumDuration: 10,
            maximumPacketCount: 10
        )

        XCTAssertEqual(
            PlaybackCompressedPacketBufferPolicy
                .blockingFutureSubtitleEvictionIndices(
                    packets: [
                        PlaybackCompressedPacketFootprint(
                            byteCount: 100,
                            timelineStart: 0,
                            timelineEnd: 0,
                            isSubtitle: false
                        ),
                        PlaybackCompressedPacketFootprint(
                            byteCount: 100,
                            timelineStart: 10,
                            timelineEnd: 10,
                            isSubtitle: false
                        ),
                        PlaybackCompressedPacketFootprint(
                            byteCount: 20,
                            timelineStart: 70,
                            timelineEnd: 70,
                            isSubtitle: true
                        ),
                    ],
                    subtitleReadyThrough: 12,
                    limits: limits
                ),
            []
        )
    }
}
