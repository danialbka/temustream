import Foundation

/// Keeps transient UI and app-lifecycle events from restarting an already
/// running media clock. Genuine pauses, seeks, and audio interruptions still
/// request an explicit rate change.
public enum PlaybackContinuityPolicy {
    /// Resolves a relative seek against the newest authoritative playhead.
    ///
    /// A resumed player can expose its controls while the decoder clock is
    /// still at zero. Until that initial restore completes, the persisted
    /// resume position is therefore more authoritative than `currentPosition`.
    /// An in-flight user seek remains the highest-priority anchor so repeated
    /// 15-second taps continue to accumulate predictably.
    public static func relativeSeekTarget(
        by interval: TimeInterval,
        currentPosition: TimeInterval,
        pendingPosition: TimeInterval?,
        initialResumePosition: TimeInterval?,
        duration: TimeInterval,
        endTolerance: TimeInterval = 0.25
    ) -> TimeInterval {
        let base: TimeInterval
        if let pendingPosition, pendingPosition.isFinite {
            base = max(pendingPosition, 0)
        } else if let initialResumePosition, initialResumePosition.isFinite {
            base = max(initialResumePosition, 0)
        } else if currentPosition.isFinite {
            base = max(currentPosition, 0)
        } else {
            base = 0
        }

        let delta = interval.isFinite ? interval : 0
        let proposed = base + delta
        let lowerBounded = proposed.isFinite ? max(proposed, 0) : base
        guard duration.isFinite, duration > 0 else { return lowerBounded }
        let upperBound = max(duration - max(endTolerance, 0), 0)
        return min(lowerBounded, upperBound)
    }

    public static func requiresClockRateChange(
        currentRate: Float,
        requestedRate: Float,
        tolerance: Float = 0.0001
    ) -> Bool {
        guard currentRate.isFinite, requestedRate.isFinite else { return true }
        return abs(currentRate - requestedRate) > max(tolerance, 0)
    }

    public static func shouldResumeAfterCancelledScrub(
        wasScrubbing: Bool,
        wantsPlayback: Bool,
        isPreparing: Bool
    ) -> Bool {
        wasScrubbing && wantsPlayback && !isPreparing
    }
}
