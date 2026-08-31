import XCTest
@testable import StremioSkeletonCore

final class TorBoxStreamSelectionTests: XCTestCase {
    func testParsesDecimalProviderSize() {
        XCTAssertEqual(
            TorBoxStreamSelection.expectedSizeBytes(
                in: ["Obsession 1080p", "💾 4.96 GB", nil]
            ),
            4_960_000_000
        )
    }

    func testParsesFortyThroughTerabyteProviderSizesWithoutNarrowing() {
        let cases: [([String?], Int64)] = [
            (["💾 40 GiB"], 40 * 1_024 * 1_024 * 1_024),
            (["Remux", "55.48 GB"], 55_480_000_000),
            (["80 GB", "2160p"], 80_000_000_000),
            (["1.10 TB"], 1_100_000_000_000),
        ]

        for (metadata, expected) in cases {
            XCTAssertEqual(
                TorBoxStreamSelection.expectedSizeBytes(in: metadata),
                expected
            )
        }
    }

    func testRejectsRoundedInt64UpperBoundaryInsteadOfTrapping() {
        XCTAssertNil(
            TorBoxStreamSelection.expectedSizeBytes(
                in: ["9223372.036854776 TB"]
            )
        )
    }

    func testDetectsSampleSizedResponse() {
        XCTAssertTrue(
            TorBoxStreamSelection.shouldRepair(
                expectedSizeBytes: 4_960_000_000,
                resolvedSizeBytes: 24_000_000
            )
        )
        XCTAssertFalse(
            TorBoxStreamSelection.shouldRepair(
                expectedSizeBytes: 4_960_000_000,
                resolvedSizeBytes: 4_700_000_000
            )
        )
    }

    func testSelectsMainVideoInsteadOfSample() {
        let files = [
            TorBoxFileCandidate(
                id: 0,
                name: "Sample/sample.mp4",
                shortName: "sample.mp4",
                size: 24_000_000,
                mimetype: "video/mp4"
            ),
            TorBoxFileCandidate(
                id: 1,
                name: "Obsession.2025.mp4",
                shortName: "Obsession.2025.mp4",
                size: 4_958_000_000,
                mimetype: "video/mp4"
            ),
            TorBoxFileCandidate(
                id: 2,
                name: "Obsession.2025.srt",
                shortName: "Obsession.2025.srt",
                size: 80_000,
                mimetype: "text/plain"
            ),
        ]

        XCTAssertEqual(
            TorBoxStreamSelection.replacementFileID(
                files: files,
                currentFileID: 0,
                expectedSizeBytes: 4_960_000_000
            ),
            1
        )
    }
}
