import Foundation
import XCTest
@testable import StremioSkeletonCore

final class MPEGTransportHLSManifestTests: XCTestCase {
    func testBuildsPacketAlignedByteRangePlaylistWithoutDroppingBytes() throws {
        let layout = try MPEGTransportHLSManifest.build(
            contentLength: 67_108_864,
            duration: 215.896033
        )

        XCTAssertGreaterThan(layout.segments.count, 1)
        XCTAssertEqual(layout.segmentByteLength % 188, 0)
        XCTAssertEqual(layout.segments.first?.offset, 0)
        XCTAssertEqual(
            layout.segments.reduce(Int64(0)) { $0 + $1.length },
            layout.contentLength
        )
        for pair in zip(layout.segments, layout.segments.dropFirst()) {
            XCTAssertEqual(pair.0.offset + pair.0.length, pair.1.offset)
            XCTAssertEqual(pair.1.offset % 188, 0)
        }

        let text = try XCTUnwrap(String(data: layout.encoded(), encoding: .utf8))
        XCTAssertTrue(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertEqual(
            text.components(separatedBy: "#EXT-X-BYTERANGE:").count - 1,
            layout.segments.count
        )
        XCTAssertTrue(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testFortyGigabyteSourceStaysWithinBoundedManifestSize() throws {
        let fortyGiB = Int64(40) * 1_024 * 1_024 * 1_024
        let layout = try MPEGTransportHLSManifest.build(
            contentLength: fortyGiB,
            duration: 3 * 60 * 60
        )

        XCTAssertLessThanOrEqual(layout.segments.count, 8_192)
        XCTAssertEqual(layout.segments.reduce(0) { $0 + $1.length }, fortyGiB)
        XCTAssertLessThan(layout.encoded().count, 1_000_000)
    }

    func testEightyGigabyteSourceUsesExactInt64ByteCoverage() throws {
        let eightyGB: Int64 = 80_000_000_000
        let layout = try MPEGTransportHLSManifest.build(
            contentLength: eightyGB,
            duration: 3 * 60 * 60
        )

        XCTAssertLessThanOrEqual(layout.segments.count, 8_192)
        XCTAssertEqual(layout.segments.reduce(0) { $0 + $1.length }, eightyGB)
        XCTAssertEqual(layout.segments.last.map { $0.offset + $0.length }, eightyGB)
    }

    func testOneTerabyteSourceDoesNotHitAnArtificialSegmentCountCeiling() throws {
        let oneTB: Int64 = 1_000_000_000_000
        let layout = try MPEGTransportHLSManifest.build(
            contentLength: oneTB,
            duration: 10 * 60 * 60
        )

        XCTAssertLessThanOrEqual(layout.segments.count, 8_192)
        XCTAssertEqual(layout.segments.reduce(0) { $0 + $1.length }, oneTB)
        XCTAssertLessThan(layout.encoded().count, 1_000_000)
    }

    func testRejectsInvalidOrUnrepresentableInputs() {
        XCTAssertThrowsError(
            try MPEGTransportHLSManifest.build(contentLength: 0, duration: 10)
        )
        XCTAssertThrowsError(
            try MPEGTransportHLSManifest.build(contentLength: 100, duration: .infinity)
        )
        XCTAssertThrowsError(
            try MPEGTransportHLSManifest.build(
                contentLength: 1_000_000,
                duration: 10,
                minimumSegmentBytes: 188,
                maximumSegmentBytes: 188,
                maximumSegmentCount: 1
            )
        )
    }
}
