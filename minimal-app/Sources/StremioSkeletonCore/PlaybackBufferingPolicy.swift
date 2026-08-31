import Foundation

public struct PlaybackBufferingDecision: Equatable, Sendable {
    public let appliedRate: Float
    public let isRebuffering: Bool

    public init(appliedRate: Float, isRebuffering: Bool) {
        self.appliedRate = appliedRate
        self.isRebuffering = isRebuffering
    }
}

/// Hysteresis for Bunny's sample-buffer clock.
///
/// The render synchronizer advances independently of the network and demuxer.
/// Letting that clock run past the common queued A/V tail produces a frozen
/// picture followed by catch-up movement. This policy pauses the applied clock
/// before starvation and resumes only after a useful reserve has accumulated.
public enum PlaybackBufferingPolicy {
    // AVSampleBufferDisplayLayer on the 4K seek path accepted about 0.82s of
    // paused video before applying backpressure. Keep the resume threshold
    // safely below that measured capacity so rebuffering cannot deadlock.
    public static let resumeReserve: TimeInterval = 0.70
    /// A paused 4K display renderer accepts only a handful of uncompressed
    /// frames. Once VideoToolbox already has a safe presentation-ordered
    /// backlog, let the clock drain that queue before renderer backpressure
    /// deadlocks further decode submissions.
    public static let predecodedVideoResumeReserve: TimeInterval = 0.20
    /// Keep decoded Apple renderer queues small and paced. Longer reserves stay
    /// in Bunny's compressed packet reservoir, where a stale readiness signal
    /// cannot turn a network burst into hundreds of late decoded frames.
    public static let maximumRendererQueueLead: TimeInterval = 1.25
    public static let videoTimingCalibrationPacketLimit = 48
    public static let videoTimingCalibrationSpan: TimeInterval = 2

    /// `AVSampleBufferAudioRenderer` can keep reporting backpressure after a
    /// flush while its synchronizer is stopped at a seek target. The seek
    /// cannot complete until the selected audio track consumes its preroll and
    /// reaches the first sample at the target, which creates a circular wait if
    /// normal renderer readiness remains the only admission signal.
    ///
    /// Permit that bounded seek preroll even while readiness is stale. The
    /// caller still applies the normal renderer-lead cap, and this exception
    /// ends as soon as the seek transition completes.
    public static func audioRendererCanAcceptPacket(
        rendererIsReady: Bool,
        hasPendingSeekTransition: Bool
    ) -> Bool {
        rendererIsReady || hasPendingSeekTransition
    }

    /// Matroska carries PTS but no authoritative DTS. Measure one decode-order
    /// GOP before enqueueing video, then apply one stable, millisecond-quantized
    /// lead to the monotonic decode timeline. A stable offset preserves DTS
    /// order while ensuring every reordered B-frame is decoded before its PTS.
    public static func videoDecodeLead(
        maximumObservedLag: TimeInterval,
        timestampStep: TimeInterval = 0.001
    ) -> TimeInterval {
        let lag = max(maximumObservedLag, 0)
        let quantizedLag: TimeInterval
        if timestampStep.isFinite, timestampStep > 0 {
            quantizedLag = ceil(lag / timestampStep) * timestampStep
        } else {
            quantizedLag = lag
        }
        // Explicit VideoToolbox decompression supplies practical decode runway
        // before presentation. DTS therefore needs only the measured reorder
        // lead; adding presentation runway here makes temporal decoding retain
        // an unnecessary second of 4K frames.
        return quantizedLag
    }

    public static func videoTimingCalibrationReady(
        keyframeCount: Int,
        packetCount: Int,
        decodeSpan: TimeInterval,
        reservoirIsFull: Bool
    ) -> Bool {
        max(keyframeCount, 0) >= 2
            || max(packetCount, 0) >= videoTimingCalibrationPacketLimit
            || max(decodeSpan, 0) >= videoTimingCalibrationSpan
            || reservoirIsFull
    }

    /// A compressed video stream is enqueued in decode order, while its PTS
    /// can jump hundreds of milliseconds forward and then backward for
    /// reordered B-frames. The farthest PTS is therefore not contiguous queued
    /// coverage. Monotonic DTS is the conservative frontier: when packet N is
    /// decoded, every earlier decode step is available, but a future-reference
    /// PTS from packet N must not start the playback clock early.
    public static func contiguousVideoQueueEnd(
        previousEnd: TimeInterval,
        presentationTime: TimeInterval,
        decodeTime: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let candidate: TimeInterval
        if decodeTime.isFinite {
            candidate = decodeTime
        } else if presentationTime.isFinite {
            candidate = presentationTime + max(duration.isFinite ? duration : 0, 0)
        } else {
            return previousEnd
        }
        return max(previousEnd, candidate)
    }

    public static func decision(
        desiredRate: Float,
        isRebuffering: Bool,
        clock: TimeInterval,
        videoQueueEnd: TimeInterval,
        audioQueueEnd: TimeInterval,
        hasVideo: Bool,
        hasAudio: Bool,
        nominalFrameRate: Double,
        allowsLowReservePlayback: Bool = false,
        reachedEnd: Bool,
        requiredResumeReserve: TimeInterval = resumeReserve,
        decodedVideoBacklogEnd: TimeInterval? = nil
    ) -> PlaybackBufferingDecision {
        let effectiveVideoQueueEnd = effectiveVideoQueueEnd(
            rendererQueueEnd: videoQueueEnd,
            decodedBacklogEnd: decodedVideoBacklogEnd
        )
        guard desiredRate > 0 else {
            let reserve = commonReserve(
                clock: clock,
                videoQueueEnd: effectiveVideoQueueEnd,
                audioQueueEnd: audioQueueEnd,
                hasVideo: hasVideo,
                hasAudio: hasAudio
            )
            return PlaybackBufferingDecision(
                appliedRate: 0,
                isRebuffering: reserve.map { $0 < requiredResumeReserve } ?? true
            )
        }

        // No additional samples can arrive at EOF. Let the already queued tail
        // drain instead of entering a permanent buffering state near the end.
        if reachedEnd {
            return PlaybackBufferingDecision(
                appliedRate: desiredRate,
                isRebuffering: false
            )
        }

        // Immediately after a seek, AVSampleBufferDisplayLayer may need the
        // timebase to advance briefly before it releases hidden preroll
        // samples. A short bounded grace avoids deadlocking that renderer; the
        // normal underrun threshold takes over as soon as the grace expires.
        if allowsLowReservePlayback {
            return PlaybackBufferingDecision(
                appliedRate: desiredRate,
                isRebuffering: false
            )
        }

        guard let reserve = commonReserve(
            clock: clock,
            videoQueueEnd: effectiveVideoQueueEnd,
            audioQueueEnd: audioQueueEnd,
            hasVideo: hasVideo,
            hasAudio: hasAudio
        ) else {
            return PlaybackBufferingDecision(appliedRate: 0, isRebuffering: true)
        }

        if isRebuffering {
            guard reserve >= requiredResumeReserve else {
                return PlaybackBufferingDecision(appliedRate: 0, isRebuffering: true)
            }
            return PlaybackBufferingDecision(
                appliedRate: desiredRate,
                isRebuffering: false
            )
        }

        let frameDuration = nominalFrameRate > 0
            ? 1 / nominalFrameRate
            : 0.05
        let underrunReserve = min(max(frameDuration * 2, 0.08), 0.25)
        if reserve <= underrunReserve {
            return PlaybackBufferingDecision(appliedRate: 0, isRebuffering: true)
        }
        return PlaybackBufferingDecision(
            appliedRate: desiredRate,
            isRebuffering: false
        )
    }

    /// VideoToolbox can safely hold decoded presentation-ordered frames beyond
    /// AVSampleBufferDisplayLayer's small paused queue. Treat that deliverable
    /// frontier as real video coverage so the clock does not repeatedly stop
    /// while the presentation pump still has contiguous frames ready.
    public static func effectiveVideoQueueEnd(
        rendererQueueEnd: TimeInterval,
        decodedBacklogEnd: TimeInterval?
    ) -> TimeInterval {
        guard let decodedBacklogEnd, decodedBacklogEnd.isFinite else {
            return rendererQueueEnd
        }
        guard rendererQueueEnd.isFinite else { return decodedBacklogEnd }
        return max(rendererQueueEnd, decodedBacklogEnd)
    }

    public static func commonReserve(
        clock: TimeInterval,
        videoQueueEnd: TimeInterval,
        audioQueueEnd: TimeInterval,
        hasVideo: Bool,
        hasAudio: Bool
    ) -> TimeInterval? {
        let queueEnd: TimeInterval
        switch (hasVideo, hasAudio) {
        case (true, true):
            guard videoQueueEnd.isFinite, audioQueueEnd.isFinite else { return nil }
            queueEnd = min(videoQueueEnd, audioQueueEnd)
        case (true, false):
            guard videoQueueEnd.isFinite else { return nil }
            queueEnd = videoQueueEnd
        case (false, true):
            guard audioQueueEnd.isFinite else { return nil }
            queueEnd = audioQueueEnd
        case (false, false):
            return .infinity
        }
        return max(queueEnd - clock, 0)
    }
}
