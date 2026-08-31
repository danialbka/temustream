import Foundation
import XCTest
@testable import StremioSkeletonCore

final class StreamPresentationPolicyTests: XCTestCase {
    func testLargeProviderResultsRemainVisibleAndAreNotDownrankedBySize() {
        let inputs = [
            presented(id: "40", title: "1080p BluRay 40.00 GB"),
            presented(id: "55", title: "1080p BluRay 55.48 GB"),
            presented(id: "tb", title: "1080p BluRay 1.10 TB"),
            presented(id: "small", title: "720p WEB 2.00 GB"),
        ]

        let ranked = StreamPresentationPolicy.ranked(inputs)

        XCTAssertEqual(Set(ranked.map(\.id)), Set(inputs.map(\.id)))
        XCTAssertEqual(ranked.count, inputs.count)
        XCTAssertEqual(ranked.filter { $0.id != "small" }.map(\.playbackPriority), [-120, -120, -120])
        XCTAssertEqual(
            Set(ranked.compactMap(\.fileSizeBadge)),
            ["40.00 GB", "55.48 GB", "1.10 TB", "2.00 GB"]
        )
        XCTAssertLessThan(
            ranked.firstIndex(where: { $0.id == "55" })!,
            ranked.firstIndex(where: { $0.id == "small" })!
        )
    }

    func testCurrentRankingPinsEveryCachedStreamAboveUncachedStreams() {
        let inputs = [
            presented(id: "uncached-1080", title: "1080p BluRay 12.00 GB"),
            presented(id: "cached-8k", title: "⚡ 8K WEB 80.00 GB"),
            presented(id: "cached-720", title: "⚡ 720p WEB 2.00 GB"),
        ]

        let ranked = StreamPresentationPolicy.ranked(inputs, mode: .current)

        XCTAssertEqual(ranked.map(\.id), ["cached-720", "cached-8k", "uncached-1080"])
        XCTAssertTrue(ranked.prefix(2).allSatisfy(\.isCached))
    }

    func testBiggestFilesRankingPinsCachedThenSortsEachTierBySize() {
        let inputs = [
            presented(id: "uncached-unknown", title: "1080p WEB"),
            presented(id: "cached-small", title: "⚡ 1080p WEB 2.00 GB"),
            presented(id: "uncached-40", title: "1080p BluRay 40.00 GB"),
            presented(id: "cached-large", title: "⚡ 720p REMUX 55.48 GB"),
            presented(id: "uncached-tb", title: "4K REMUX 1.10 TB"),
        ]

        let ranked = StreamPresentationPolicy.ranked(inputs, mode: .biggestFiles)

        XCTAssertEqual(
            ranked.map(\.id),
            ["cached-large", "cached-small", "uncached-tb", "uncached-40", "uncached-unknown"]
        )
        XCTAssertEqual(ranked.count, inputs.count)
        XCTAssertGreaterThan(
            ranked.first { $0.id == "uncached-tb" }!.fileSizeBytes!,
            ranked.first { $0.id == "uncached-40" }!.fileSizeBytes!
        )
    }

    func testRejectsRoundedInt64UpperBoundaryInsteadOfTrapping() {
        let stream = presented(id: "boundary", title: "8388608 TB")

        XCTAssertNil(stream.fileSizeBytes)
        XCTAssertNil(stream.fileSizeBadge)
    }

    private func presented(id: String, title: String) -> PresentedStream {
        PresentedStream(
            id: id,
            providerID: "provider-\(id)",
            providerName: "Provider \(id)",
            stream: Stream(
                url: URL(string: "https://example.com/\(id).mkv"),
                externalUrl: nil,
                name: nil,
                title: title,
                description: nil,
                infoHash: nil,
                fileIdx: nil,
                sources: nil
            )
        )
    }
}
