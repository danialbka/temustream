import Foundation

/// Bounded byte-range geometry for Bunny's remote random-access reader.
public enum PlaybackRangeChunkPolicy {
    public static let metadataChunkBytes: UInt64 = 2 * 1024 * 1024
    public static let streamingChunkBytes: UInt64 = 8 * 1024 * 1024
    public static let largeSourceThresholdBytes: UInt64 = 40_000_000_000
    public static let ordinaryPrefetchDepth = 2
    public static let largeSourcePrefetchDepth = 4
    /// A random seek needs the ranges immediately following its target before
    /// farther speculative data. Two lanes preserve ordered priority while
    /// retaining enough aggregate throughput to rebuild the 4K reservoir.
    public static let largeSourceInitialSeekPrefetchDepth = 2
    /// Ordinary files retain the short latency-first grace. Large remuxes use
    /// 8 MiB speculative ranges. Starting a foreground bridge after 200 ms was
    /// too eager, but waiting seven seconds made rapid seek/resume interactions
    /// visibly freeze behind one slow speculative response. One second gives
    /// the normal prefetch a head start while keeping recovery bounded.
    public static let ordinaryPrefetchCompletionGraceMilliseconds = 200
    public static let largeSourcePrefetchCompletionGraceMilliseconds = 1_000
    public static let foregroundBridgeChunkBytes: UInt64 = 2 * 1024 * 1024
    public static let ordinaryMaximumRetainedCacheBytes: Int = 40 * 1024 * 1024
    public static let largeSourceMaximumRetainedCacheBytes: Int = 24 * 1024 * 1024
    public static let maximumInFlightForegroundBytes: Int = 8 * 1024 * 1024

    /// Large remuxes consume an 8 MiB range in roughly one second. Four
    /// speculative ranges give a slow CDN response time to finish before it
    /// becomes the ordered demux range. Ordinary files retain the existing
    /// two-range policy. The cache is reduced for large sources so both modes
    /// remain bounded to the same 64 MiB aggregate reader budget.
    public static func prefetchDepth(sourceLength: UInt64) -> Int {
        sourceLength >= largeSourceThresholdBytes
            ? largeSourcePrefetchDepth
            : ordinaryPrefetchDepth
    }

    public static func initialSeekPrefetchDepth(sourceLength: UInt64) -> Int {
        sourceLength >= largeSourceThresholdBytes
            ? largeSourceInitialSeekPrefetchDepth
            : ordinaryPrefetchDepth
    }

    public static func maximumRetainedCacheBytes(sourceLength: UInt64) -> Int {
        sourceLength >= largeSourceThresholdBytes
            ? largeSourceMaximumRetainedCacheBytes
            : ordinaryMaximumRetainedCacheBytes
    }

    public static func prefetchCompletionGraceMilliseconds(
        sourceLength: UInt64
    ) -> Int {
        sourceLength >= largeSourceThresholdBytes
            ? largeSourcePrefetchCompletionGraceMilliseconds
            : ordinaryPrefetchCompletionGraceMilliseconds
    }

    public static func maximumInFlightPrefetchBytes(sourceLength: UInt64) -> Int {
        Int(streamingChunkBytes) * prefetchDepth(sourceLength: sourceLength)
    }

    public static func maximumBufferedBytes(sourceLength: UInt64) -> Int {
        maximumRetainedCacheBytes(sourceLength: sourceLength)
            + maximumInFlightPrefetchBytes(sourceLength: sourceLength)
            + maximumInFlightForegroundBytes
    }

    /// Returns the ranges that should already be in flight after a consumed
    /// range. The first streaming window must start as soon as the 2 MiB
    /// metadata prefix is available; waiting for the first 8 MiB body read
    /// leaves high-bitrate remote files with no useful read-ahead at startup.
    public static func prefetchRanges(
        after consumedRange: Range<UInt64>,
        sourceLength: UInt64,
        depth: Int
    ) -> [Range<UInt64>] {
        guard depth > 0,
              consumedRange.lowerBound < consumedRange.upperBound,
              consumedRange.upperBound <= sourceLength
        else { return [] }

        let metadataUpperBound = min(metadataChunkBytes, sourceLength)
        let consumedMetadataPrefix = consumedRange.lowerBound == 0
            && consumedRange.upperBound == metadataUpperBound
        let consumedStreamingRange = consumedRange.lowerBound >= metadataChunkBytes
            && consumedRange.count == Int(streamingChunkBytes)
        guard consumedMetadataPrefix || consumedStreamingRange else { return [] }

        var ranges: [Range<UInt64>] = []
        var nextOffset = consumedRange.upperBound
        for _ in 0..<depth {
            guard let range = byteRange(
                containing: nextOffset,
                sourceLength: sourceLength
            ), range.count == Int(streamingChunkBytes)
            else { break }
            ranges.append(range)
            nextOffset = range.upperBound
        }
        return ranges
    }

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

    public static func foregroundBridgeRange(
        startingAt offset: UInt64,
        within pendingRange: Range<UInt64>,
        sourceLength: UInt64
    ) -> Range<UInt64>? {
        guard pendingRange.contains(offset), offset < sourceLength else { return nil }
        let (candidateUpperBound, overflowed) = offset.addingReportingOverflow(
            foregroundBridgeChunkBytes
        )
        let upperBound = overflowed
            ? min(pendingRange.upperBound, sourceLength)
            : min(candidateUpperBound, pendingRange.upperBound, sourceLength)
        guard upperBound > offset else { return nil }
        return offset..<upperBound
    }

}

/// Restores only the non-sensitive headers that define a byte-range media
/// request after URLSession constructs a redirect request. URLSession may
/// remove `Range` while following provider resolver URLs; without restoring
/// it, the origin sends the entire movie and the bounded reader correctly
/// rejects that response as oversized.
public enum PlaybackRangeRedirectPolicy {
    public static func request(
        preservingHeadersFrom source: URLRequest?,
        for redirect: URLRequest
    ) -> URLRequest {
        guard let source else { return redirect }
        var redirected = redirect
        for header in ["Range", "Accept-Encoding"]
        where redirected.value(forHTTPHeaderField: header) == nil {
            if let value = source.value(forHTTPHeaderField: header) {
                redirected.setValue(value, forHTTPHeaderField: header)
            }
        }
        return redirected
    }
}
