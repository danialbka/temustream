import Foundation

/// Classifies decoder preroll around an explicit playback seek.
///
/// Compressed video must still decode the frames between the preceding random
/// access point and the requested timestamp, but those frames should not be
/// presented to the viewer. Audio packets that finish before the requested
/// timestamp can be discarded entirely.
public enum PlaybackSeekTransitionPolicy {
    public static func sampleIsEntirelyBeforeTarget(
        presentationTime: TimeInterval,
        duration: TimeInterval,
        targetTime: TimeInterval,
        tolerance: TimeInterval = 0.000_001
    ) -> Bool {
        guard presentationTime.isFinite, targetTime.isFinite else { return false }
        let tolerance = max(tolerance, 0)
        guard duration.isFinite, duration > 0 else {
            return presentationTime < targetTime - tolerance
        }
        let sampleEnd = presentationTime + duration
        guard sampleEnd.isFinite else { return false }
        return sampleEnd <= targetTime + tolerance
    }

    public static func shouldDiscardVideoBeforeRandomAccessPoint(
        isKeyframe: Bool,
        isWaitingForRandomAccessPoint: Bool
    ) -> Bool {
        isWaitingForRandomAccessPoint && !isKeyframe
    }
}
