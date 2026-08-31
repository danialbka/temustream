import XCTest
@testable import StremioSkeletonCore

final class PlaybackTrackSelectionPacketPolicyTests: XCTestCase {
    func testSelectingCurrentAudioTrackDoesNotReprimeTimeline() {
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.requiresAudioTimelineReprime(
                currentStreamIndex: 2,
                requestedStreamIndex: 2
            )
        )
    }

    func testChangingAudioTrackReprimesTimeline() {
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.requiresAudioTimelineReprime(
                currentStreamIndex: 2,
                requestedStreamIndex: 5
            )
        )
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.requiresAudioTimelineReprime(
                currentStreamIndex: nil,
                requestedStreamIndex: 0
            )
        )
    }

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

    func testIntentionalTrackSelectionInterruptRetriesItsReadFailure() {
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.preservesCompletedReadFailure(
                readWasInFlightWhenInterruptedForTrackSelection: true
            )
        )
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.preservesCompletedReadFailure(
                readWasInFlightWhenInterruptedForTrackSelection: false
            )
        )
    }

    func testSamePendingOrCurrentSubtitleSelectionIsANoop() {
        let selectable: Set<Int> = [3, 7]
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: 3,
                hasPendingSelection: false,
                pendingStreamIndex: nil,
                requestedStreamIndex: 3,
                selectableStreamIndices: selectable
            )
        )
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: nil,
                hasPendingSelection: true,
                pendingStreamIndex: 7,
                requestedStreamIndex: 7,
                selectableStreamIndices: selectable
            )
        )
    }

    func testSelectedSubtitleRowAndAlreadyOffAreModelNoops() {
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.shouldApplySubtitleOptionSelection(
                currentOptionID: 7,
                requestedOptionID: 7
            )
        )
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.shouldApplySubtitleOptionSelection(
                currentOptionID: Optional<Int>.none,
                requestedOptionID: Optional<Int>.none
            )
        )
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.shouldApplySubtitleOptionSelection(
                currentOptionID: 7,
                requestedOptionID: Optional<Int>.none
            )
        )
    }

    func testInvalidSubtitleSelectionIsRejectedBeforeOwnershipChanges() {
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: 3,
                hasPendingSelection: false,
                pendingStreamIndex: nil,
                requestedStreamIndex: 99,
                selectableStreamIndices: [3, 7]
            )
        )
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: 3,
                hasPendingSelection: false,
                pendingStreamIndex: nil,
                requestedStreamIndex: nil,
                selectableStreamIndices: [3, 7]
            )
        )
    }

    func testPendingDisableAndNoPendingSelectionRemainDistinct() {
        let selectable: Set<Int> = [3]
        XCTAssertTrue(
            PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: 3,
                hasPendingSelection: true,
                pendingStreamIndex: nil,
                requestedStreamIndex: 3,
                selectableStreamIndices: selectable
            )
        )
        XCTAssertFalse(
            PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: 3,
                hasPendingSelection: false,
                pendingStreamIndex: nil,
                requestedStreamIndex: 3,
                selectableStreamIndices: selectable
            )
        )
    }

    func testInvisibleAudioAndVideoDecodeWithoutPresentation() {
        for kind in [PlaybackPacketTrackKind.audio, .video] {
            XCTAssertEqual(
                PlaybackMediaPacketVisibilityPolicy.disposition(
                    kind: kind,
                    isInvisible: true
                ),
                .decodeWithoutPresentation
            )
            XCTAssertEqual(
                PlaybackMediaPacketVisibilityPolicy.disposition(
                    kind: kind,
                    isInvisible: false
                ),
                .present
            )
        }
    }

    func testInvisibleTextIsDiscardedButStatefulSubtitleStillDecodes() {
        XCTAssertEqual(
            PlaybackMediaPacketVisibilityPolicy.disposition(
                kind: .subtitle,
                isInvisible: true,
                subtitleRequiresDecoderState: false
            ),
            .discard
        )
        XCTAssertEqual(
            PlaybackMediaPacketVisibilityPolicy.disposition(
                kind: .subtitle,
                isInvisible: true,
                subtitleRequiresDecoderState: true
            ),
            .decodeWithoutPresentation
        )
        XCTAssertEqual(
            PlaybackMediaPacketVisibilityPolicy.disposition(
                kind: .subtitle,
                isInvisible: false,
                subtitleRequiresDecoderState: true
            ),
            .present
        )
    }

    func testProducerRefillCannotExtendOneSubtitleMainActorTurn() {
        var source = Array(0..<400)
        var pending = Array(source.prefix(128))
        source.removeFirst(pending.count)
        var delivered: [Int] = []
        var batchSizes: [Int] = []

        while !pending.isEmpty {
            let batchSize = PlaybackSubtitleDeliveryPolicy.batchSize(
                pendingCount: pending.count
            )
            batchSizes.append(batchSize)
            delivered.append(contentsOf: pending.prefix(batchSize))
            pending.removeFirst(batchSize)

            let refillCount = min(batchSize, source.count)
            pending.append(contentsOf: source.prefix(refillCount))
            source.removeFirst(refillCount)
        }

        XCTAssertEqual(delivered, Array(0..<400))
        XCTAssertGreaterThan(batchSizes.count, 1)
        XCTAssertTrue(
            batchSizes.allSatisfy {
                $0 > 0
                    && $0 <= PlaybackSubtitleDeliveryPolicy
                        .maximumDeliveriesPerMainActorTurn
            }
        )
    }

    func testOldSubtitleGenerationCannotCrossSeekBoundary() {
        let oldGeneration: UInt64 = 7
        let seekGeneration: UInt64 = 8

        XCTAssertFalse(
            PlaybackSubtitleDeliveryPolicy.accepts(
                deliveryGeneration: oldGeneration,
                currentGeneration: seekGeneration
            )
        )
        XCTAssertTrue(
            PlaybackSubtitleDeliveryPolicy.accepts(
                deliveryGeneration: seekGeneration,
                currentGeneration: seekGeneration
            )
        )
    }

    func testOldSubtitleGenerationCannotCrossTrackSwitchBoundary() {
        let oldTrackGeneration: UInt64 = 11
        let selectedTrackGeneration: UInt64 = 12

        XCTAssertFalse(
            PlaybackSubtitleDeliveryPolicy.accepts(
                deliveryGeneration: oldTrackGeneration,
                currentGeneration: selectedTrackGeneration
            )
        )
        XCTAssertTrue(
            PlaybackSubtitleDeliveryPolicy.accepts(
                deliveryGeneration: selectedTrackGeneration,
                currentGeneration: selectedTrackGeneration
            )
        )
    }

    func testSelectThenSeekBeforeWorkerDoesNotRegressAppliedGeneration() {
        let selectionGeneration: UInt64 = 1
        let seekGeneration: UInt64 = 2
        var appliedGeneration: UInt64 = 0

        appliedGeneration = PlaybackSubtitleDeliveryPolicy.generationAfterApplying(
            currentAppliedGeneration: appliedGeneration,
            mutationGeneration: seekGeneration
        )
        appliedGeneration = PlaybackSubtitleDeliveryPolicy.generationAfterApplying(
            currentAppliedGeneration: appliedGeneration,
            mutationGeneration: selectionGeneration
        )

        XCTAssertEqual(appliedGeneration, seekGeneration)
    }

    func testSeekThenSelectBeforeWorkerAdvancesToLatestAppliedGeneration() {
        let seekGeneration: UInt64 = 1
        let selectionGeneration: UInt64 = 2
        var appliedGeneration: UInt64 = 0

        appliedGeneration = PlaybackSubtitleDeliveryPolicy.generationAfterApplying(
            currentAppliedGeneration: appliedGeneration,
            mutationGeneration: seekGeneration
        )
        appliedGeneration = PlaybackSubtitleDeliveryPolicy.generationAfterApplying(
            currentAppliedGeneration: appliedGeneration,
            mutationGeneration: selectionGeneration
        )

        XCTAssertEqual(appliedGeneration, selectionGeneration)
    }
}
