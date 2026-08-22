import Foundation

/// Pure synchronization math shared by the SharePlay playback bridge and its
/// deterministic tests. AVFoundation supplies a host-clock anchor; this type
/// projects that anchor to the media position a player should show now.
public enum WatchTogetherTiming {
    public static let defaultCorrectionTolerance: TimeInterval = 0.15

    public static func projectedPosition(
        itemTime: TimeInterval,
        rate: Double,
        commandHostTime: TimeInterval,
        localHostTime: TimeInterval,
        duration: TimeInterval? = nil
    ) -> TimeInterval {
        let elapsed = max(localHostTime - commandHostTime, 0)
        let projected = max(itemTime + elapsed * rate, 0)
        guard let duration, duration.isFinite, duration > 0 else {
            return projected
        }
        return min(projected, duration)
    }

    public static func needsCorrection(
        currentPosition: TimeInterval,
        expectedPosition: TimeInterval,
        tolerance: TimeInterval = defaultCorrectionTolerance
    ) -> Bool {
        guard currentPosition.isFinite, expectedPosition.isFinite else { return true }
        return abs(currentPosition - expectedPosition) > max(tolerance, 0)
    }
}

/// A deterministic, URL-free fallback identifier for playback surfaces that
/// do not have a catalog item identifier (for example simulator fixtures).
public enum WatchTogetherContentIdentity {
    public static func fallbackIdentifier(for title: String) -> String {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        // FNV-1a is used only for stable identity, not security. Keeping the
        // title out of the identifier also prevents a stream URL accidentally
        // supplied as fixture text from being broadcast through SharePlay.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "stremio-title-" + String(hash, radix: 16)
    }
}
