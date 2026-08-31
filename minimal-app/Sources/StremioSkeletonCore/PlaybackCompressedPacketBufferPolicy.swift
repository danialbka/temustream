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

/// The portion of one compressed packet that participates in reservoir
/// capacity decisions. Keeping this value-only lets the app prove a
/// counterfactual eviction without copying packet payloads.
public struct PlaybackCompressedPacketFootprint: Equatable, Sendable {
    public let byteCount: Int
    public let timelineStart: TimeInterval
    public let timelineEnd: TimeInterval
    public let isSubtitle: Bool

    public init(
        byteCount: Int,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        isSubtitle: Bool
    ) {
        self.byteCount = byteCount
        self.timelineStart = timelineStart
        self.timelineEnd = timelineEnd
        self.isSubtitle = isSubtitle
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

    /// Returns the smallest farthest-first subtitle subset whose removal
    /// turns a full, otherwise-stalled reservoir back into readable headroom.
    ///
    /// Callers invoke this only after no renderer packet is ready. A healthy
    /// future cue is therefore retained, and no subtitle is removed when the
    /// non-subtitle packets would keep the reservoir full by themselves.
    public static func blockingFutureSubtitleEvictionIndices(
        packets: [PlaybackCompressedPacketFootprint],
        subtitleReadyThrough: TimeInterval,
        limits: PlaybackCompressedPacketBufferLimits
    ) -> [Int] {
        guard subtitleReadyThrough.isFinite, !packets.isEmpty else { return [] }

        var timeline = PlaybackPacketTimelineIndex()
        var tokens: [PlaybackPacketTimelineIndex.Token] = []
        tokens.reserveCapacity(packets.count)
        var byteCount = 0
        for packet in packets {
            tokens.append(
                timeline.append(
                    start: packet.timelineStart,
                    end: packet.timelineEnd
                )
            )
            let safeBytes = max(packet.byteCount, 0)
            let addition = byteCount.addingReportingOverflow(safeBytes)
            byteCount = addition.overflow ? Int.max : addition.partialValue
        }

        guard isFull(
            byteCount: byteCount,
            packetCount: packets.count,
            bufferedDuration: timeline.duration,
            limits: limits
        ) else { return [] }

        let candidates = packets.indices.filter { index in
            let packet = packets[index]
            return packet.isSubtitle
                && packet.timelineStart.isFinite
                && packet.timelineStart > subtitleReadyThrough
        }.sorted { lhs, rhs in
            let left = packets[lhs]
            let right = packets[rhs]
            if left.timelineStart == right.timelineStart {
                return left.timelineEnd > right.timelineEnd
            }
            return left.timelineStart > right.timelineStart
        }

        var removed: [Int] = []
        removed.reserveCapacity(candidates.count)
        var packetCount = packets.count
        for index in candidates {
            timeline.remove(tokens[index])
            byteCount = max(byteCount - max(packets[index].byteCount, 0), 0)
            packetCount = max(packetCount - 1, 0)
            removed.append(index)
            if !isFull(
                byteCount: byteCount,
                packetCount: packetCount,
                bufferedDuration: timeline.duration,
                limits: limits
            ) {
                return removed.sorted()
            }
        }

        // A/V or other packets remain independently full. Removing every
        // future subtitle would not restore progress, so preserve them all.
        return []
    }
}
