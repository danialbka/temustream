import Foundation

/// Bounded byte-range geometry for Bunny's remote random-access reader.
public enum PlaybackRangeChunkPolicy {
    public static let metadataChunkBytes: UInt64 = 2 * 1024 * 1024
    public static let streamingChunkBytes: UInt64 = 8 * 1024 * 1024
    public static let prefetchDepth = 2
    public static let maximumRetainedCacheBytes: Int = 40 * 1024 * 1024
    public static let maximumInFlightPrefetchBytes: Int = Int(streamingChunkBytes)
        * prefetchDepth
    public static let maximumInFlightForegroundBytes: Int = 8 * 1024 * 1024
    public static let maximumBufferedBytes: Int = maximumRetainedCacheBytes
        + maximumInFlightPrefetchBytes
        + maximumInFlightForegroundBytes

    public static func byteRange(
        containing offset: UInt64,
        sourceLength: UInt64
    ) -> Range<UInt64>? {
        guard offset < sourceLength else { return nil }
        let lowerBound: UInt64
        let chunkBytes: UInt64
        if offset < metadataChunkBytes {
            lowerBound = 0
            chunkBytes = metadataChunkBytes
        } else {
            let streamingOffset = offset - metadataChunkBytes
            lowerBound = metadataChunkBytes
                + (streamingOffset / streamingChunkBytes) * streamingChunkBytes
            chunkBytes = streamingChunkBytes
        }
        let (candidateUpperBound, overflowed) = lowerBound.addingReportingOverflow(
            chunkBytes
        )
        let upperBound = overflowed
            ? sourceLength
            : min(candidateUpperBound, sourceLength)
        guard upperBound > lowerBound else { return nil }
        return lowerBound..<upperBound
    }
}
