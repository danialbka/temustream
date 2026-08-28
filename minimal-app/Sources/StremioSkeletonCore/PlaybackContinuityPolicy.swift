import Foundation

/// Keeps transient UI and app-lifecycle events from restarting an already
/// running media clock. Genuine pauses, seeks, and audio interruptions still
/// request an explicit rate change.
public enum PlaybackContinuityPolicy {
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
