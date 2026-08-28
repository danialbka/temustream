import Foundation

public struct PlaybackCompressedPacketBufferLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumDuration: TimeInterval
    public let maximumPacketCount: Int

    public init(
        maximumBytes: Int,
        maximumDuration: TimeInterval,
        maximumPacketCount: Int
    ) {
        self.maximumBytes = maximumBytes
        self.maximumDuration = maximumDuration
        self.maximumPacketCount = maximumPacketCount
    }
}

/// Memory-bounded read-ahead for Bunny's compressed Matroska packets.
///
/// Keeping this reserve compressed separates short provider/range jitter from
/// Apple's much smaller decoded renderer queues without retaining seconds of
/// full-resolution video surfaces.
public enum PlaybackCompressedPacketBufferPolicy {
    public static let maximumPacketCount = 8_192
    // A 55 GB 4K remux can consume an 8 MiB range in well under a second,
    // while a provider tail occasionally takes several seconds to arrive.
    // Begin the existing fill-to-capacity burst with one quarter of the
    // reservoir consumed so the four speculative range lanes have useful
    // runway before the decoded queue becomes exposed to network jitter.
    public static let refillLowWatermarkFraction = 0.75
    /// Matches the proven forward-buffer target of the former player while
    /// keeping Bunny's reserve compressed and well below its mobile cap.
    public static let preferredRemotePrerollDuration: TimeInterval = 3

    public static func limits(width: Int, height: Int) -> PlaybackCompressedPacketBufferLimits {
        let safeWidth = max(width, 0)
        let safeHeight = max(height, 0)
        let pixels = safeWidth.multipliedReportingOverflow(by: safeHeight)
        let pixelCount = pixels.overflow ? Int.max : pixels.partialValue

        if max(safeWidth, safeHeight) >= 3_000 {
            return PlaybackCompressedPacketBufferLimits(
                maximumBytes: 64 * 1_024 * 1_024,
                maximumDuration: 10,
                maximumPacketCount: maximumPacketCount
            )
        }
        if pixelCount >= 1_920 * 1_080 {
            return PlaybackCompressedPacketBufferLimits(
                maximumBytes: 32 * 1_024 * 1_024,
                maximumDuration: 8,
                maximumPacketCount: maximumPacketCount
            )
        }
        return PlaybackCompressedPacketBufferLimits(
            maximumBytes: 16 * 1_024 * 1_024,
            maximumDuration: 8,
            maximumPacketCount: maximumPacketCount
        )
    }

    public static func isFull(
        byteCount: Int,
        packetCount: Int,
        bufferedDuration: TimeInterval,
        limits: PlaybackCompressedPacketBufferLimits
    ) -> Bool {
        max(byteCount, 0) >= limits.maximumBytes
            || max(packetCount, 0) >= limits.maximumPacketCount
            || max(bufferedDuration, 0) >= limits.maximumDuration
    }

    public static func hasRemotePreroll(
        bufferedDuration: TimeInterval,
        isFull: Bool,
        requiresFullBuffer: Bool = false
    ) -> Bool {
        if requiresFullBuffer { return isFull }
        return isFull || max(bufferedDuration, 0) >= preferredRemotePrerollDuration
    }

    /// Keep range fetching bursty enough to advance every speculative lane.
    /// Replacing each decoded packet immediately turns an otherwise parallel
    /// byte-range window into serial drip feeding on high-bitrate remuxes.
    public static func shouldRefill(
        isRefilling: Bool,
        byteCount: Int,
        packetCount: Int,
        bufferedDuration: TimeInterval,
        limits: PlaybackCompressedPacketBufferLimits
    ) -> Bool {
        if isFull(
            byteCount: byteCount,
            packetCount: packetCount,
            bufferedDuration: bufferedDuration,
            limits: limits
        ) {
            return false
        }
        if isRefilling { return true }
        let byteFraction = Double(max(byteCount, 0))
            / Double(max(limits.maximumBytes, 1))
        let packetFraction = Double(max(packetCount, 0))
            / Double(max(limits.maximumPacketCount, 1))
        let durationFraction = max(bufferedDuration, 0)
            / max(limits.maximumDuration, 0.001)
        return max(byteFraction, packetFraction, durationFraction)
            <= refillLowWatermarkFraction
    }
}
