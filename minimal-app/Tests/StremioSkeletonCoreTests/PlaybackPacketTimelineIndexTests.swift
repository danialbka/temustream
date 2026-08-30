import XCTest
@testable import StremioSkeletonCore

final class PlaybackPacketTimelineIndexTests: XCTestCase {
    func testRemovingLatestOutOfOrderEntryLowersReportedDuration() throws {
        var index = PlaybackPacketTimelineIndex()
        _ = index.append(start: 10, end: 11)
        _ = index.append(start: 11, end: 12)
        let farthest = index.append(start: 12, end: 30)

        XCTAssertEqual(index.duration, 20, accuracy: 0.001)
        index.remove(farthest)
        XCTAssertEqual(index.duration, 2, accuracy: 0.001)
    }

    func testRemovingEarliestOutOfOrderEntryRaisesLowerBound() throws {
        var index = PlaybackPacketTimelineIndex()
        let earliest = index.append(start: 2, end: 4)
        _ = index.append(start: 8, end: 10)
        _ = index.append(start: 6, end: 9)

        index.remove(earliest)

        let bounds = try XCTUnwrap(index.bounds)
        XCTAssertEqual(bounds.earliestStart, 6, accuracy: 0.001)
        XCTAssertEqual(bounds.latestEnd, 10, accuracy: 0.001)
        XCTAssertEqual(bounds.duration, 4, accuracy: 0.001)
    }

    func testRemovingInteriorEntryPreservesExactEnvelope() throws {
        var index = PlaybackPacketTimelineIndex()
        _ = index.append(start: 1, end: 3)
        let interior = index.append(start: 2, end: 5)
        _ = index.append(start: 4, end: 8)

        index.remove(interior)

        XCTAssertEqual(try XCTUnwrap(index.bounds).duration, 7, accuracy: 0.001)
        XCTAssertEqual(index.count, 2)
    }

    func testLongFIFOChurnCompactsLazyHeapStorage() throws {
        var index = PlaybackPacketTimelineIndex()
        var liveTokens = [PlaybackPacketTimelineIndex.Token]()
        for packet in 0..<32 {
            liveTokens.append(
                index.append(
                    start: TimeInterval(packet),
                    end: TimeInterval(packet + 1)
                )
            )
        }

        for packet in 32..<10_000 {
            index.remove(liveTokens.removeFirst())
            liveTokens.append(
                index.append(
                    start: TimeInterval(packet),
                    end: TimeInterval(packet + 1)
                )
            )
        }

        let bounds = try XCTUnwrap(index.bounds)
        XCTAssertEqual(index.count, 32)
        XCTAssertEqual(bounds.earliestStart, 9_968, accuracy: 0.001)
        XCTAssertEqual(bounds.latestEnd, 10_000, accuracy: 0.001)
        XCTAssertLessThanOrEqual(index.heapNodeCount, 512)
    }
}
