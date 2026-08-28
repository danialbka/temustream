import XCTest
@testable import StremioSkeletonCore

final class PlaybackRangeChunkPolicyTests: XCTestCase {
    func testRedirectRestoresRangeHeadersWithoutForwardingCredentials() throws {
        var source = URLRequest(url: try XCTUnwrap(URL(string: "https://resolver.example/video")))
        source.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        source.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        source.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv")))
        proposed.setValue("redirect", forHTTPHeaderField: "X-Request-Source")

        let redirected = PlaybackRangeRedirectPolicy.request(
            preservingHeadersFrom: source,
            for: proposed
        )

        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=0-0")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "X-Request-Source"), "redirect")
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    }

    func testRedirectKeepsServerProposedRangeHeader() throws {
        var source = URLRequest(url: try XCTUnwrap(URL(string: "https://resolver.example/video")))
        source.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        var proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv")))
        proposed.setValue("bytes=10-19", forHTTPHeaderField: "Range")

        let redirected = PlaybackRangeRedirectPolicy.request(
            preservingHeadersFrom: source,
            for: proposed
        )

        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=10-19")
    }

    func testMetadataRangeStaysSmall() {
        let range = PlaybackRangeChunkPolicy.byteRange(
            containing: 1024,
            sourceLength: 80 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(range, 0..<(2 * 1024 * 1024))
    }

    func testStreamingRangeStartsAfterMetadataWithoutOverlap() {
        let twoMiB = UInt64(2 * 1024 * 1024)
        let range = PlaybackRangeChunkPolicy.byteRange(
            containing: twoMiB,
            sourceLength: 80 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(range, twoMiB..<(twoMiB + 8 * 1024 * 1024))
    }

    func testEightyGiBOffsetUsesBoundedEightMiBChunk() throws {
        let sourceLength = UInt64(80 * 1024 * 1024 * 1024)
        let offset = UInt64(55 * 1024 * 1024 * 1024 + 123_456)
        let range = try XCTUnwrap(
            PlaybackRangeChunkPolicy.byteRange(
                containing: offset,
                sourceLength: sourceLength
            )
        )
        XCTAssertTrue(range.contains(offset))
        XCTAssertLessThanOrEqual(range.count, Int(8 * 1024 * 1024))
        XCTAssertLessThanOrEqual(range.upperBound, sourceLength)
    }

    func testTailRangeIsClampedToSourceLength() throws {
        let sourceLength = UInt64(40 * 1024 * 1024 * 1024 + 123)
        let range = try XCTUnwrap(
            PlaybackRangeChunkPolicy.byteRange(
                containing: sourceLength - 1,
                sourceLength: sourceLength
            )
        )
        XCTAssertEqual(range.upperBound, sourceLength)
        XCTAssertLessThanOrEqual(range.count, Int(8 * 1024 * 1024))
    }

    func testOrdinaryCacheAndReadAheadTogetherRemainSixtyFourMiB() {
        let sourceLength: UInt64 = 7_090_000_000
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.prefetchDepth(sourceLength: sourceLength),
            2
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.prefetchCompletionGraceMilliseconds(
                sourceLength: sourceLength
            ),
            200
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.foregroundBridgeChunkBytes,
            2 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumRetainedCacheBytes(
                sourceLength: sourceLength
            ),
            40 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumInFlightPrefetchBytes(
                sourceLength: sourceLength
            ),
            16 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumInFlightForegroundBytes,
            8 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumBufferedBytes(
                sourceLength: sourceLength
            ),
            64 * 1024 * 1024
        )
    }

    func testLargeSourceTradesCacheForFourRangeReadAheadWithinSameBudget() {
        let sourceLength = PlaybackRangeChunkPolicy.largeSourceThresholdBytes
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.prefetchDepth(sourceLength: sourceLength),
            4
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.initialSeekPrefetchDepth(
                sourceLength: sourceLength
            ),
            2
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumRetainedCacheBytes(
                sourceLength: sourceLength
            ),
            24 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumInFlightPrefetchBytes(
                sourceLength: sourceLength
            ),
            32 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumBufferedBytes(
                sourceLength: sourceLength
            ),
            64 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.prefetchCompletionGraceMilliseconds(
                sourceLength: sourceLength
            ),
            1_000
        )
    }

    func testMetadataPrefixImmediatelySeedsLargeFileStreamingWindow() {
        let twoMiB = UInt64(2 * 1024 * 1024)
        let eightMiB = UInt64(8 * 1024 * 1024)
        let ranges = PlaybackRangeChunkPolicy.prefetchRanges(
            after: 0..<twoMiB,
            sourceLength: 80 * 1024 * 1024 * 1024,
            depth: 4
        )

        XCTAssertEqual(ranges, [
            twoMiB..<(twoMiB + eightMiB),
            (twoMiB + eightMiB)..<(twoMiB + 2 * eightMiB),
            (twoMiB + 2 * eightMiB)..<(twoMiB + 3 * eightMiB),
            (twoMiB + 3 * eightMiB)..<(twoMiB + 4 * eightMiB),
        ])
    }

    func testPartialForegroundBridgeDoesNotShiftPrefetchWindow() {
        let twoMiB = UInt64(2 * 1024 * 1024)
        XCTAssertTrue(
            PlaybackRangeChunkPolicy.prefetchRanges(
                after: twoMiB..<(2 * twoMiB),
                sourceLength: 80 * 1024 * 1024 * 1024,
                depth: 4
            ).isEmpty
        )
    }

    func testSourceImmediatelyBelowFortyGBKeepsOrdinaryPolicy() {
        let sourceLength = PlaybackRangeChunkPolicy.largeSourceThresholdBytes - 1
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.prefetchDepth(sourceLength: sourceLength),
            2
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.initialSeekPrefetchDepth(
                sourceLength: sourceLength
            ),
            2
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumRetainedCacheBytes(
                sourceLength: sourceLength
            ),
            40 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.prefetchCompletionGraceMilliseconds(
                sourceLength: sourceLength
            ),
            200
        )
    }

    func testForegroundBridgeBoundsAHeadOfLineRangeToTwoMiB() throws {
        let eightMiB = UInt64(8 * 1024 * 1024)
        let pending = eightMiB..<(2 * eightMiB)
        let range = try XCTUnwrap(
            PlaybackRangeChunkPolicy.foregroundBridgeRange(
                startingAt: pending.lowerBound,
                within: pending,
                sourceLength: 80 * 1024 * 1024 * 1024
            )
        )
        XCTAssertEqual(range, eightMiB..<(eightMiB + 2 * 1024 * 1024))
    }

    func testForegroundBridgeStopsAtPendingRangeTail() throws {
        let pending = UInt64(10_000)..<UInt64(11_000)
        let range = try XCTUnwrap(
            PlaybackRangeChunkPolicy.foregroundBridgeRange(
                startingAt: 10_750,
                within: pending,
                sourceLength: 80 * 1024 * 1024 * 1024
            )
        )
        XCTAssertEqual(range, UInt64(10_750)..<UInt64(11_000))
    }

    func testForegroundBridgeRejectsOffsetOutsidePendingRange() {
        XCTAssertNil(
            PlaybackRangeChunkPolicy.foregroundBridgeRange(
                startingAt: 20_000,
                within: UInt64(10_000)..<UInt64(11_000),
                sourceLength: 80 * 1024 * 1024 * 1024
            )
        )
    }
}
