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
        reachedEnd: Bool
    ) -> PlaybackBufferingDecision {
        guard desiredRate > 0 else {
            let reserve = commonReserve(
                clock: clock,
                videoQueueEnd: videoQueueEnd,
                audioQueueEnd: audioQueueEnd,
                hasVideo: hasVideo,
                hasAudio: hasAudio
            )
            return PlaybackBufferingDecision(
                appliedRate: 0,
                isRebuffering: reserve.map { $0 < resumeReserve } ?? true
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
            videoQueueEnd: videoQueueEnd,
            audioQueueEnd: audioQueueEnd,
            hasVideo: hasVideo,
            hasAudio: hasAudio
        ) else {
            return PlaybackBufferingDecision(appliedRate: 0, isRebuffering: true)
        }

        if isRebuffering {
            guard reserve >= resumeReserve else {
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
