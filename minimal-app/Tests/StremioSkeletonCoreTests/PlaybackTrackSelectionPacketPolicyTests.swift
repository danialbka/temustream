import XCTest
@testable import StremioSkeletonCore

final class PlaybackTrackSelectionPacketPolicyTests: XCTestCase {
    func testAudioSelectionPreservesCompletedVideoKeyframe() {
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                kind: .video,
                audioSelectionChanged: true,
                subtitleSelectionChanged: false
            )
        )
    }

    func testAudioSelectionDropsCompletedPacketFromOldAudioTrack() {
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                kind: .audio,
                audioSelectionChanged: true,
                subtitleSelectionChanged: false
            )
        )
    }

    func testSubtitleSelectionDropsOnlyOldSubtitlePacket() {
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                kind: .subtitle,
                audioSelectionChanged: false,
                subtitleSelectionChanged: true
            )
        )
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                kind: .audio,
                audioSelectionChanged: false,
                subtitleSelectionChanged: true
            )
        )
    }

    func testNoEffectiveSelectionChangePreservesEveryPacketClass() {
        for kind in [
            PlaybackPacketTrackKind.video,
            .audio,
            .subtitle,
            .other,
        ] {
            XCTAssertTrue(
                PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                    kind: kind,
                    audioSelectionChanged: false,
                    subtitleSelectionChanged: false
                )
            )
        }
    }
}
