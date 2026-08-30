import Foundation

enum BunnyNativeRecoverySeekReason: String, Equatable, Sendable {
    case automaticAudioRendererFlush
    case audioTrackSelection
    case userSeekFailure
    case userSeekTimeout
}

enum BunnyNativeSeekIntent: Equatable, Sendable {
    case user(requestID: UInt64)
    case recovery(
        requestID: UInt64?,
        reason: BunnyNativeRecoverySeekReason
    )

    var userRequestID: UInt64? {
        guard case let .user(requestID) = self else { return nil }
        return requestID
    }

    var recoveryRequestID: UInt64? {
        guard case let .recovery(requestID, _) = self else { return nil }
        return requestID
    }

    var recoveryReason: BunnyNativeRecoverySeekReason? {
        guard case let .recovery(_, reason) = self else { return nil }
        return reason
    }
}

struct BunnyNativeSeekRequest: Equatable, Sendable {
    let intent: BunnyNativeSeekIntent
    let targetTime: TimeInterval
}

struct BunnyNativeSeekTransition {
    let intent: BunnyNativeSeekIntent
    let targetTime: TimeInterval
    var videoReady: Bool
    var audioReady: Bool
    var isWaitingForVideoRandomAccessPoint: Bool
    var hiddenVideoFrames = 0
    var discardedAudioPackets = 0
    var discardedVideoPacketsBeforeRandomAccessPoint = 0

    init(
        intent: BunnyNativeSeekIntent,
        targetTime: TimeInterval,
        hasVideo: Bool,
        hasAudio: Bool
    ) {
        self.intent = intent
        self.targetTime = targetTime
        videoReady = !hasVideo
        audioReady = !hasAudio
        isWaitingForVideoRandomAccessPoint = hasVideo
    }

    var isReady: Bool {
        videoReady && audioReady
    }
}

/// Compressed-packet ownership and readiness live outside the decoder
/// orchestrator. Timeline bounds are delegated to a tested exact index because
/// renderer backpressure intentionally removes packets out of insertion order.
struct BunnyNativePacketReservoir {
    private struct Entry {
        let packet: BunnyNativePacket
        let kind: UInt32
        let timelineStart: TimeInterval
        let timelineEnd: TimeInterval
        let timelineToken: PlaybackPacketTimelineIndex.Token
    }

    private var entries: [Entry?] = []
    private var firstLiveIndex = 0
    private(set) var byteCount = 0
    private(set) var packetCount = 0
    private var videoPacketCount = 0
    private var audioPacketCount = 0
    private var subtitlePacketCount = 0
    private var timelineIndex = PlaybackPacketTimelineIndex()
    private(set) var observedVideoPacketCount = 0
    private(set) var observedVideoKeyframeCount = 0
    private(set) var maximumObservedVideoDecodeLag: TimeInterval = 0
    private var firstObservedVideoDecodeTime: TimeInterval?
    private var latestObservedVideoDecodeTime: TimeInterval?
    let limits: PlaybackCompressedPacketBufferLimits

    init(width: Int, height: Int) {
        limits = PlaybackCompressedPacketBufferPolicy.limits(width: width, height: height)
    }

    var isEmpty: Bool { packetCount == 0 }

    var bufferedDuration: TimeInterval {
        mutating get { timelineIndex.duration }
    }

    var isFull: Bool {
        mutating get {
            PlaybackCompressedPacketBufferPolicy.isFull(
                byteCount: byteCount,
                packetCount: packetCount,
                bufferedDuration: bufferedDuration,
                limits: limits
            )
        }
    }

    var observedVideoDecodeSpan: TimeInterval {
        guard let firstObservedVideoDecodeTime,
              let latestObservedVideoDecodeTime
        else { return 0 }
        return max(latestObservedVideoDecodeTime - firstObservedVideoDecodeTime, 0)
    }

    var videoTimingCalibrationReady: Bool {
        mutating get {
            PlaybackBufferingPolicy.videoTimingCalibrationReady(
                keyframeCount: observedVideoKeyframeCount,
                packetCount: observedVideoPacketCount,
                decodeSpan: observedVideoDecodeSpan,
                reservoirIsFull: isFull
            )
        }
    }

    mutating func append(_ packet: BunnyNativePacket, kind: UInt32) {
        let presentationTime = packet.presentationTime.seconds
        let decodeTime = packet.decodeTime.seconds
        let duration = packet.duration.seconds
        let previousTimelineEnd = timelineIndex.bounds?.latestEnd ?? 0
        let timelineStart = decodeTime.isFinite
            ? decodeTime
            : (presentationTime.isFinite ? presentationTime : previousTimelineEnd)
        let timelineEnd = presentationTime.isFinite
            ? presentationTime + max(duration.isFinite ? duration : 0, 0)
            : timelineStart
        let timelineToken = timelineIndex.append(
            start: timelineStart,
            end: timelineEnd
        )
        entries.append(Entry(
            packet: packet,
            kind: kind,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            timelineToken: timelineToken
        ))
        byteCount += packet.data.count
        packetCount += 1
        switch kind {
        case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
            videoPacketCount += 1
            observedVideoPacketCount += 1
            if packet.flags & UInt32(STREMIO_MEDIA_PACKET_KEYFRAME) != 0 {
                observedVideoKeyframeCount += 1
            }
            if decodeTime.isFinite, presentationTime.isFinite {
                maximumObservedVideoDecodeLag = max(
                    maximumObservedVideoDecodeLag,
                    max(decodeTime - presentationTime, 0)
                )
                firstObservedVideoDecodeTime = firstObservedVideoDecodeTime ?? decodeTime
                latestObservedVideoDecodeTime = max(
                    latestObservedVideoDecodeTime ?? decodeTime,
                    decodeTime
                )
            }
        case UInt32(STREMIO_MEDIA_TRACK_AUDIO): audioPacketCount += 1
        case UInt32(STREMIO_MEDIA_TRACK_SUBTITLE): subtitlePacketCount += 1
        default: break
        }
    }

    /// Preserves packet order within each renderer while allowing audio or
    /// subtitles to pass a temporarily backpressured video renderer.
    mutating func takeReady(videoReady: Bool, audioReady: Bool) -> BunnyNativePacket? {
        guard (videoReady && videoPacketCount > 0)
                || (audioReady && audioPacketCount > 0)
                || subtitlePacketCount > 0
        else { return nil }

        var sawVideo = false
        var sawAudio = false
        var sawSubtitle = false

        for index in firstLiveIndex..<entries.count {
            guard let entry = entries[index] else { continue }
            let ready: Bool
            switch entry.kind {
            case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
                guard !sawVideo else { continue }
                sawVideo = true
                ready = videoReady
            case UInt32(STREMIO_MEDIA_TRACK_AUDIO):
                guard !sawAudio else { continue }
                sawAudio = true
                ready = audioReady
            case UInt32(STREMIO_MEDIA_TRACK_SUBTITLE):
                guard !sawSubtitle else { continue }
                sawSubtitle = true
                ready = true
            default:
                ready = true
            }
            guard ready else { continue }
            return remove(at: index)
        }
        return nil
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        firstLiveIndex = 0
        byteCount = 0
        packetCount = 0
        videoPacketCount = 0
        audioPacketCount = 0
        subtitlePacketCount = 0
        timelineIndex.removeAll(keepingCapacity: keepingCapacity)
        observedVideoPacketCount = 0
        observedVideoKeyframeCount = 0
        maximumObservedVideoDecodeLag = 0
        firstObservedVideoDecodeTime = nil
        latestObservedVideoDecodeTime = nil
    }

    mutating func removeAll(kind: UInt32) {
        let retained = entries.compactMap { $0 }.filter { $0.kind != kind }
        entries.removeAll(keepingCapacity: true)
        timelineIndex.removeAll(keepingCapacity: true)
        for entry in retained {
            let token = timelineIndex.append(
                start: entry.timelineStart,
                end: entry.timelineEnd
            )
            entries.append(Entry(
                packet: entry.packet,
                kind: entry.kind,
                timelineStart: entry.timelineStart,
                timelineEnd: entry.timelineEnd,
                timelineToken: token
            ))
        }
        firstLiveIndex = 0
        byteCount = retained.reduce(into: 0) { $0 += $1.packet.data.count }
        packetCount = retained.count
        videoPacketCount = retained.reduce(into: 0) {
            if $1.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO) { $0 += 1 }
        }
        audioPacketCount = retained.reduce(into: 0) {
            if $1.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO) { $0 += 1 }
        }
        subtitlePacketCount = retained.reduce(into: 0) {
            if $1.kind == UInt32(STREMIO_MEDIA_TRACK_SUBTITLE) { $0 += 1 }
        }
        if kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO) {
            observedVideoPacketCount = 0
            observedVideoKeyframeCount = 0
            maximumObservedVideoDecodeLag = 0
            firstObservedVideoDecodeTime = nil
            latestObservedVideoDecodeTime = nil
        }
    }

    private mutating func remove(at index: Int) -> BunnyNativePacket? {
        guard entries.indices.contains(index), let entry = entries[index] else { return nil }
        entries[index] = nil
        timelineIndex.remove(entry.timelineToken)
        byteCount = max(byteCount - entry.packet.data.count, 0)
        packetCount = max(packetCount - 1, 0)
        switch entry.kind {
        case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
            videoPacketCount = max(videoPacketCount - 1, 0)
        case UInt32(STREMIO_MEDIA_TRACK_AUDIO):
            audioPacketCount = max(audioPacketCount - 1, 0)
        case UInt32(STREMIO_MEDIA_TRACK_SUBTITLE):
            subtitlePacketCount = max(subtitlePacketCount - 1, 0)
        default:
            break
        }

        if index == firstLiveIndex {
            while firstLiveIndex < entries.count {
                if case .some = entries[firstLiveIndex] { break }
                firstLiveIndex += 1
            }
        }
        if packetCount == 0 {
            removeAll()
        } else if firstLiveIndex >= 1_024, firstLiveIndex * 2 >= entries.count {
            entries.removeFirst(firstLiveIndex)
            firstLiveIndex = 0
        }
        return entry.packet
    }
}
