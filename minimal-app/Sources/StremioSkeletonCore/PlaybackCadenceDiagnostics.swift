import Foundation

/// A bounded view of presentation timestamps in the order the demuxer hands
/// them to the decoder. Negative intervals are not automatically failures --
/// codecs with reordered pictures can legitimately produce them -- but the
/// shape of those intervals helps distinguish source timing from renderer lag.
public struct PlaybackTimestampCadenceSnapshot: Equatable, Sendable {
    public let observedFrames: Int
    public let windowTransitions: Int
    public let backwardTransitions: Int
    public let duplicateTransitions: Int
    public let medianForwardIntervalMilliseconds: Double?
    public let p95ForwardIntervalMilliseconds: Double?
    public let maximumForwardIntervalMilliseconds: Double?
    public let expectedIntervalMilliseconds: Double?
    public let irregularForwardTransitions: Int
}

public struct PlaybackTimestampCadenceTracker: Sendable {
    private let capacity: Int
    private let expectedInterval: TimeInterval?
    private var intervals: [TimeInterval] = []
    private var replacementIndex = 0
    private var previousPresentationTime: TimeInterval?
    private var observedFrames = 0

    public init(nominalFrameRate: Double, capacity: Int = 240) {
        self.capacity = max(capacity, 1)
        expectedInterval = nominalFrameRate.isFinite && nominalFrameRate > 0
            ? 1 / nominalFrameRate
            : nil
        intervals.reserveCapacity(self.capacity)
    }

    public mutating func observe(presentationTime: TimeInterval) {
        guard presentationTime.isFinite else { return }
        observedFrames += 1
        defer { previousPresentationTime = presentationTime }
        guard let previousPresentationTime else { return }
        append(presentationTime - previousPresentationTime)
    }

    /// Clears the timing window at a seek/discontinuity so the intentional
    /// jump is never reported as source jitter.
    public mutating func reset() {
        intervals.removeAll(keepingCapacity: true)
        replacementIndex = 0
        previousPresentationTime = nil
        observedFrames = 0
    }

    public func snapshot() -> PlaybackTimestampCadenceSnapshot {
        let backwards = intervals.filter { $0 < -0.000_001 }.count
        let duplicates = intervals.filter { abs($0) <= 0.000_001 }.count
        let forward = intervals.filter { $0 > 0.000_001 }.sorted()
        let irregular: Int
        if let expectedInterval {
            let tolerance = max(expectedInterval * 0.35, 0.002)
            irregular = forward.filter { abs($0 - expectedInterval) > tolerance }.count
        } else {
            irregular = 0
        }
        return PlaybackTimestampCadenceSnapshot(
            observedFrames: observedFrames,
            windowTransitions: intervals.count,
            backwardTransitions: backwards,
            duplicateTransitions: duplicates,
            medianForwardIntervalMilliseconds: percentile(forward, fraction: 0.50),
            p95ForwardIntervalMilliseconds: percentile(forward, fraction: 0.95),
            maximumForwardIntervalMilliseconds: forward.last.map { $0 * 1_000 },
            expectedIntervalMilliseconds: expectedInterval.map { $0 * 1_000 },
            irregularForwardTransitions: irregular
        )
    }

    private mutating func append(_ interval: TimeInterval) {
        if intervals.count < capacity {
            intervals.append(interval)
            return
        }
        intervals[replacementIndex] = interval
        replacementIndex = (replacementIndex + 1) % capacity
    }

    private func percentile(_ sorted: [TimeInterval], fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)] * 1_000
    }
}

public struct PlaybackRendererCumulativeMetrics: Equatable, Sendable {
    public let totalFrames: Int
    public let droppedFrames: Int
    public let corruptedFrames: Int
    public let accumulatedFrameDelay: TimeInterval

    public init(
        totalFrames: Int,
        droppedFrames: Int,
        corruptedFrames: Int,
        accumulatedFrameDelay: TimeInterval
    ) {
        self.totalFrames = max(totalFrames, 0)
        self.droppedFrames = max(droppedFrames, 0)
        self.corruptedFrames = max(corruptedFrames, 0)
        self.accumulatedFrameDelay = max(accumulatedFrameDelay, 0)
    }
}

public struct PlaybackRendererCadenceSnapshot: Equatable, Sendable {
    public let totalFrames: Int
    public let totalDroppedFrames: Int
    public let totalCorruptedFrames: Int
    public let intervalFrames: Int
    public let intervalDroppedFrames: Int
    public let intervalCorruptedFrames: Int
    public let displayedFramesPerSecond: Double
    public let averageFrameDelayMilliseconds: Double
    public let countersReset: Bool
}

/// Turns Apple's cumulative renderer counters into one bounded interval. A
/// flush may reset those counters; treating the new values as a fresh baseline
/// avoids negative FPS or delay values in seek diagnostics.
public enum PlaybackRendererCadenceDiagnostics {
    public static func interval(
        previous: PlaybackRendererCumulativeMetrics,
        current: PlaybackRendererCumulativeMetrics,
        elapsed: TimeInterval
    ) -> PlaybackRendererCadenceSnapshot {
        let reset = current.totalFrames < previous.totalFrames
            || current.droppedFrames < previous.droppedFrames
            || current.corruptedFrames < previous.corruptedFrames
            || current.accumulatedFrameDelay < previous.accumulatedFrameDelay
        let baseline = reset
            ? PlaybackRendererCumulativeMetrics(
                totalFrames: 0,
                droppedFrames: 0,
                corruptedFrames: 0,
                accumulatedFrameDelay: 0
            )
            : previous
        let frames = max(current.totalFrames - baseline.totalFrames, 0)
        let dropped = max(current.droppedFrames - baseline.droppedFrames, 0)
        let corrupted = max(current.corruptedFrames - baseline.corruptedFrames, 0)
        let displayed = max(frames - dropped, 0)
        let delay = max(
            current.accumulatedFrameDelay - baseline.accumulatedFrameDelay,
            0
        )
        return PlaybackRendererCadenceSnapshot(
            totalFrames: current.totalFrames,
            totalDroppedFrames: current.droppedFrames,
            totalCorruptedFrames: current.corruptedFrames,
            intervalFrames: frames,
            intervalDroppedFrames: dropped,
            intervalCorruptedFrames: corrupted,
            displayedFramesPerSecond: elapsed > 0 ? Double(displayed) / elapsed : 0,
            averageFrameDelayMilliseconds: displayed > 0
                ? delay * 1_000 / Double(displayed)
                : 0,
            countersReset: reset
        )
    }
}
