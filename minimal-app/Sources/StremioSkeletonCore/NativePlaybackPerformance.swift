import Foundation

public enum NativePlaybackPerformanceHealth: String, Equatable, Sendable {
    case warmingUp = "warming_up"
    case good
    case attention
}

public struct NativePlaybackPerformanceSnapshot: Equatable, Sendable {
    public let startupMilliseconds: Double?
    public let wallDuration: TimeInterval
    public let mediaDuration: TimeInterval
    public let clockRatio: Double?
    public let bufferSeconds: TimeInterval?
    public let stalls: Int
    public let droppedVideoFrames: Int?
    public let observedBitrate: Double?
    public let indicatedBitrate: Double?
    public let health: NativePlaybackPerformanceHealth

    public var logDescription: String {
        [
            "startup_ms=\(Self.number(startupMilliseconds, digits: 1))",
            "wall_s=\(Self.number(wallDuration, digits: 2))",
            "media_s=\(Self.number(mediaDuration, digits: 2))",
            "clock=\(Self.number(clockRatio, digits: 4))",
            "buffer_s=\(Self.number(bufferSeconds, digits: 2))",
            "stalls=\(stalls)",
            "dropped=\(droppedVideoFrames.map(String.init) ?? "unknown")",
            "observed_kbps=\(Self.number(observedBitrate.map { $0 / 1_000 }, digits: 0))",
            "indicated_kbps=\(Self.number(indicatedBitrate.map { $0 / 1_000 }, digits: 0))",
            "health=\(health.rawValue)",
        ].joined(separator: " ")
    }

    private static func number(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "unknown" }
        return String(format: "%.*f", digits, value)
    }
}

/// A platform-light playback probe used by the native AVPlayer paths on Apple
/// TV and Apple Watch. The caller supplies AVFoundation counters so this type
/// remains deterministic and unit-testable without a player or network.
public struct NativePlaybackPerformanceTracker: Sendable {
    private let startedAt: TimeInterval
    private let initialPosition: TimeInterval
    private var firstPlaybackAt: TimeInterval?
    private var firstPlaybackPosition: TimeInterval?
    private var maximumStalls = 0
    private var maximumDroppedVideoFrames: Int?

    public init(startedAt: TimeInterval, initialPosition: TimeInterval) {
        self.startedAt = startedAt
        self.initialPosition = max(initialPosition, 0)
    }

    public mutating func observe(
        at timestamp: TimeInterval,
        position: TimeInterval,
        isPlaying: Bool,
        bufferSeconds: TimeInterval?,
        stalls: Int?,
        droppedVideoFrames: Int?,
        observedBitrate: Double?,
        indicatedBitrate: Double?
    ) -> NativePlaybackPerformanceSnapshot {
        let safeTimestamp = max(timestamp, startedAt)
        let safePosition = position.isFinite ? max(position, 0) : initialPosition
        if isPlaying, firstPlaybackAt == nil {
            firstPlaybackAt = safeTimestamp
            firstPlaybackPosition = safePosition
        }
        if let stalls { maximumStalls = max(maximumStalls, max(stalls, 0)) }
        if let droppedVideoFrames {
            maximumDroppedVideoFrames = max(
                maximumDroppedVideoFrames ?? 0,
                max(droppedVideoFrames, 0)
            )
        }

        let startupMilliseconds = firstPlaybackAt.map {
            max(($0 - startedAt) * 1_000, 0)
        }
        let wallDuration = firstPlaybackAt.map { max(safeTimestamp - $0, 0) } ?? 0
        let mediaDuration = firstPlaybackPosition.map {
            max(safePosition - $0, 0)
        } ?? 0
        let clockRatio = wallDuration >= 2 ? mediaDuration / wallDuration : nil
        let snapshot = NativePlaybackPerformanceSnapshot(
            startupMilliseconds: startupMilliseconds,
            wallDuration: wallDuration,
            mediaDuration: mediaDuration,
            clockRatio: clockRatio,
            bufferSeconds: bufferSeconds.map { max($0, 0) },
            stalls: maximumStalls,
            droppedVideoFrames: maximumDroppedVideoFrames,
            observedBitrate: observedBitrate,
            indicatedBitrate: indicatedBitrate,
            health: .warmingUp
        )
        return NativePlaybackPerformanceSnapshot(
            startupMilliseconds: snapshot.startupMilliseconds,
            wallDuration: snapshot.wallDuration,
            mediaDuration: snapshot.mediaDuration,
            clockRatio: snapshot.clockRatio,
            bufferSeconds: snapshot.bufferSeconds,
            stalls: snapshot.stalls,
            droppedVideoFrames: snapshot.droppedVideoFrames,
            observedBitrate: snapshot.observedBitrate,
            indicatedBitrate: snapshot.indicatedBitrate,
            health: NativePlaybackPerformancePolicy.health(for: snapshot)
        )
    }
}

public enum NativePlaybackPerformancePolicy {
    public static let minimumAssessmentDuration: TimeInterval = 8
    public static let maximumStartupMilliseconds: Double = 5_000
    public static let healthyClockRange = 0.90...1.10
    public static let maximumDroppedVideoFrames = 2

    public static func health(
        for snapshot: NativePlaybackPerformanceSnapshot
    ) -> NativePlaybackPerformanceHealth {
        guard let startup = snapshot.startupMilliseconds else {
            return .warmingUp
        }
        if startup > maximumStartupMilliseconds
            || snapshot.stalls > 0
            || (snapshot.droppedVideoFrames ?? 0) > maximumDroppedVideoFrames
        {
            return .attention
        }
        guard snapshot.wallDuration >= minimumAssessmentDuration,
              let clockRatio = snapshot.clockRatio
        else { return .warmingUp }
        return healthyClockRange.contains(clockRatio) ? .good : .attention
    }
}

public enum NativePlaybackDiagnostics {
    public static var isEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["SKELETON_PLAYBACK_DIAGNOSTICS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }
}
