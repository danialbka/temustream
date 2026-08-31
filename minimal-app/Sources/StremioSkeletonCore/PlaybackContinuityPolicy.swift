import Foundation

public struct PlaybackTerminalClockDecision: Equatable, Sendable {
    public let shouldFinish: Bool
    public let position: TimeInterval
    public let desiredRate: Float
    public let appliedRate: Float
}

/// Keeps transient UI and app-lifecycle events from restarting an already
/// running media clock. Genuine pauses, seeks, and audio interruptions still
/// request an explicit rate change.
public enum PlaybackContinuityPolicy {
    /// Keeps a public playhead inside the media timeline while preserving a
    /// useful clock for live or otherwise unknown-duration sources.
    public static func clampedTimelinePosition(
        _ position: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let nonnegativePosition = position.isFinite ? max(position, 0) : 0
        guard duration.isFinite, duration > 0 else { return nonnegativePosition }
        return min(nonnegativePosition, duration)
    }

    /// Resolves the handoff from EOF tail draining to a stable terminal clock.
    /// A known-duration source keeps advancing until its declared boundary;
    /// an unknown-duration source stops as soon as the decoder reports EOF.
    public static func terminalClockDecision(
        sampledPosition: TimeInterval,
        duration: TimeInterval,
        continuingRate: Float,
        boundaryTolerance: TimeInterval = 0.05
    ) -> PlaybackTerminalClockDecision {
        let sampledPosition = clampedTimelinePosition(
            sampledPosition,
            duration: 0
        )
        let continuingRate = continuingRate.isFinite
            ? max(continuingRate, 0)
            : 0
        guard duration.isFinite, duration > 0 else {
            return PlaybackTerminalClockDecision(
                shouldFinish: true,
                position: sampledPosition,
                desiredRate: 0,
                appliedRate: 0
            )
        }

        let boundary = max(duration - max(boundaryTolerance, 0), 0)
        guard sampledPosition >= boundary else {
            return PlaybackTerminalClockDecision(
                shouldFinish: false,
                position: sampledPosition,
                desiredRate: continuingRate,
                appliedRate: continuingRate
            )
        }
        return PlaybackTerminalClockDecision(
            shouldFinish: true,
            position: duration,
            desiredRate: 0,
            appliedRate: 0
        )
    }

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
