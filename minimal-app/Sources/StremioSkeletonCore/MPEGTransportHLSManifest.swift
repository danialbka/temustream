import Foundation

struct MPEGTransportHLSManifest: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let offset: Int64
        let length: Int64
        let duration: TimeInterval
    }

    let contentLength: Int64
    let duration: TimeInterval
    let targetDuration: Int
    let segmentByteLength: Int64
    let segments: [Segment]

    static func build(
        contentLength: Int64,
        duration: TimeInterval,
        targetSegmentDuration: TimeInterval = 12,
        minimumSegmentBytes: Int64 = 4 * 1_024 * 1_024,
        maximumSegmentBytes: Int64 = 256 * 1_024 * 1_024,
        maximumSegmentCount: Int64 = 8_192
    ) throws -> Self {
        guard contentLength > 0,
              duration.isFinite,
              duration > 0,
              targetSegmentDuration.isFinite,
              targetSegmentDuration > 0,
              minimumSegmentBytes >= 188,
              maximumSegmentBytes >= minimumSegmentBytes,
              maximumSegmentCount > 0
        else {
            throw MPEGTransportHLSManifestError.invalidMedia
        }

        let bytesPerSecond = Double(contentLength) / duration
        let targetBytes = Int64((bytesPerSecond * targetSegmentDuration).rounded())
        let countBoundedBytes = max(
            (contentLength + maximumSegmentCount - 1) / maximumSegmentCount,
            minimumSegmentBytes
        )
        let unclampedBytes = max(targetBytes, countBoundedBytes)
        let clampedBytes = min(
            max(unclampedBytes, minimumSegmentBytes),
            maximumSegmentBytes
        )
        let segmentByteLength = max((clampedBytes / 188) * 188, 188)
        let segmentCount = (contentLength + segmentByteLength - 1) / segmentByteLength
        guard segmentCount > 0, segmentCount <= maximumSegmentCount else {
            throw MPEGTransportHLSManifestError.tooManySegments
        }

        var segments: [Segment] = []
        segments.reserveCapacity(Int(segmentCount))
        var offset: Int64 = 0
        while offset < contentLength {
            let length = min(segmentByteLength, contentLength - offset)
            segments.append(
                Segment(
                    offset: offset,
                    length: length,
                    duration: duration * Double(length) / Double(contentLength)
                )
            )
            offset += length
        }
        let targetDuration = max(
            Int(ceil(segments.map(\.duration).max() ?? 1)),
            1
        )
        return Self(
            contentLength: contentLength,
            duration: duration,
            targetDuration: targetDuration,
            segmentByteLength: segmentByteLength,
            segments: segments
        )
    }

    func encoded() -> Data {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:4",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        lines.reserveCapacity(6 + segments.count * 3)
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.6f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append("media.ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

enum MPEGTransportHLSManifestError: Error, Equatable {
    case invalidMedia
    case tooManySegments
}
