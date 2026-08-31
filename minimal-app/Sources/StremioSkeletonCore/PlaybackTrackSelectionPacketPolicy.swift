/// Media-packet classes used to decide whether a completed read remains valid
/// while switching one selected track.
public enum PlaybackPacketTrackKind: Sendable {
    case video
    case audio
    case subtitle
    case other
}

/// Prevents track selection from dropping an unrelated completed packet. In
/// particular, switching to a preferred audio language must not throw away the
/// first video keyframe already returned by the demuxer.
public enum PlaybackTrackSelectionPacketPolicy {
    public static func shouldApplySubtitleOptionSelection<ID: Equatable>(
        currentOptionID: ID?,
        requestedOptionID: ID?
    ) -> Bool {
        currentOptionID != requestedOptionID
    }

    /// A no-op language preference must not flush a live audio renderer. A
    /// genuine track change needs a same-position timeline re-prime because
    /// queued timestamps from the previous renderer are no longer valid.
    public static func requiresAudioTimelineReprime(
        currentStreamIndex: Int?,
        requestedStreamIndex: Int
    ) -> Bool {
        currentStreamIndex != requestedStreamIndex
    }

    public static func preservesCompletedPacket(
        kind: PlaybackPacketTrackKind,
        audioSelectionChanged: Bool,
        subtitleSelectionChanged: Bool
    ) -> Bool {
        switch kind {
        case .audio:
            return !audioSelectionChanged
        case .subtitle:
            return !subtitleSelectionChanged
        case .video, .other:
            return true
        }
    }

    /// Track selection deliberately interrupts an in-flight source read so it
    /// can take exclusive ownership of the demuxer. A failure returned across
    /// that boundary must be retried after the reader resumes; publishing it
    /// would misreport the selection's own cancellation as a source failure.
    public static func preservesCompletedReadFailure(
        readWasInFlightWhenInterruptedForTrackSelection: Bool
    ) -> Bool {
        !readWasInFlightWhenInterruptedForTrackSelection
    }

    public static func shouldQueueSubtitleSelection(
        currentStreamIndex: Int?,
        hasPendingSelection: Bool,
        pendingStreamIndex: Int?,
        requestedStreamIndex: Int?,
        selectableStreamIndices: Set<Int>
    ) -> Bool {
        if let requestedStreamIndex,
           !selectableStreamIndices.contains(requestedStreamIndex) {
            return false
        }
        let effectiveStreamIndex = hasPendingSelection
            ? pendingStreamIndex
            : currentStreamIndex
        return effectiveStreamIndex != requestedStreamIndex
    }
}

public enum PlaybackPacketPresentationDisposition: Equatable, Sendable {
    case present
    case decodeWithoutPresentation
    case discard
}

/// Matroska's Invisible flag suppresses presentation for every Block kind,
/// while stateful compressed payloads still need to reach their decoder.
public enum PlaybackMediaPacketVisibilityPolicy {
    public static func disposition(
        kind: PlaybackPacketTrackKind,
        isInvisible: Bool,
        subtitleRequiresDecoderState: Bool = false
    ) -> PlaybackPacketPresentationDisposition {
        guard isInvisible else { return .present }
        switch kind {
        case .video, .audio:
            return .decodeWithoutPresentation
        case .subtitle:
            return subtitleRequiresDecoderState
                ? .decodeWithoutPresentation
                : .discard
        case .other:
            return .discard
        }
    }
}

/// A single generation owns one MainActor drain at a time, but each actor turn
/// must be finite even when the producer immediately refills every freed slot.
public enum PlaybackSubtitleDeliveryPolicy {
    public static let maximumDeliveriesPerMainActorTurn = 16

    public static func batchSize(pendingCount: Int) -> Int {
        min(max(pendingCount, 0), maximumDeliveriesPerMainActorTurn)
    }

    public static func accepts(
        deliveryGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        deliveryGeneration == currentGeneration
    }

    /// A mutation applied after another operation may reuse that already
    /// applied newer boundary, but it must never regress the worker token.
    /// Unapplied generations are deliberately absent from this decision.
    public static func generationAfterApplying(
        currentAppliedGeneration: UInt64,
        mutationGeneration: UInt64
    ) -> UInt64 {
        max(currentAppliedGeneration, mutationGeneration)
    }
}
