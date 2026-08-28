import XCTest
@testable import StremioSkeletonCore

final class PlaybackRangeChunkPolicyTests: XCTestCase {
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

    func testCacheAndReadAheadTogetherRemainSixtyFourMiB() {
        XCTAssertEqual(PlaybackRangeChunkPolicy.prefetchDepth, 2)
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumRetainedCacheBytes,
            40 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumInFlightPrefetchBytes,
            16 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumInFlightForegroundBytes,
            8 * 1024 * 1024
        )
        XCTAssertEqual(
            PlaybackRangeChunkPolicy.maximumBufferedBytes,
            64 * 1024 * 1024
        )
    }
}
