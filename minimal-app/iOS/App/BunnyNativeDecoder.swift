import AVFoundation
import CoreAudioTypes
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import UIKit
import VideoToolbox

let BunnyNativeDecoderErrorDomain = "BunnyNativeDecoderErrorDomain"

enum BunnyNativeTrackKind: Int, Sendable {
    case audio
    case subtitle
}

final class BunnyNativeBitmapSubtitlePart: @unchecked Sendable {
    let image: UIImage
    let sourceRect: CGRect

    init(image: UIImage, sourceRect: CGRect) {
        self.image = image
        self.sourceRect = sourceRect
    }
}

final class BunnyNativeBitmapSubtitleCue: @unchecked Sendable {
    let parts: [BunnyNativeBitmapSubtitlePart]
    let sourceSize: CGSize

    init(parts: [BunnyNativeBitmapSubtitlePart], sourceSize: CGSize) {
        self.parts = parts
        self.sourceSize = sourceSize
    }
}

final class BunnyNativeTrack: @unchecked Sendable {
    let streamIndex: Int
    let kind: BunnyNativeTrackKind
    let title: String
    let language: String?
    let codecName: String
    let sampleRate: Double
    let channelCount: Int

    init(
        streamIndex: Int,
        kind: BunnyNativeTrackKind,
        title: String,
        language: String?,
        codecName: String,
        sampleRate: Double,
        channelCount: Int
    ) {
        self.streamIndex = streamIndex
        self.kind = kind
        self.title = title
        self.language = language
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

final class BunnyNativeMediaInfo: @unchecked Sendable {
    let duration: TimeInterval
    let presentationSize: CGSize
    let nominalFrameRate: Double
    let hasVideo: Bool
    let hasAudio: Bool
    let containerName: String
    let videoCodecName: String?
    let audioCodecName: String?
    let audioTracks: [BunnyNativeTrack]
    let subtitleTracks: [BunnyNativeTrack]
    let selectedAudioStreamIndex: Int
    let selectedSubtitleStreamIndex: Int

    init(
        duration: TimeInterval,
        presentationSize: CGSize,
        nominalFrameRate: Double,
        hasVideo: Bool,
        hasAudio: Bool,
        containerName: String,
        videoCodecName: String?,
        audioCodecName: String?,
        audioTracks: [BunnyNativeTrack],
        subtitleTracks: [BunnyNativeTrack],
        selectedAudioStreamIndex: Int,
        selectedSubtitleStreamIndex: Int
    ) {
        self.duration = duration
        self.presentationSize = presentationSize
        self.nominalFrameRate = nominalFrameRate
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.containerName = containerName
        self.videoCodecName = videoCodecName
        self.audioCodecName = audioCodecName
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.selectedAudioStreamIndex = selectedAudioStreamIndex
        self.selectedSubtitleStreamIndex = selectedSubtitleStreamIndex
    }
}

/// A lock-protected snapshot of the packets Bunny has handed to Apple's
/// renderers. Diagnostics read this directly so a delayed MainActor callback
/// cannot turn stale queue positions into a false playback-stall report.
struct BunnyNativeMetricsSnapshot: Sendable {
    let decodedVideoFrames: Int
    let droppedVideoFrames: Int
    let renderedAudioFrames: Int
    let videoQueueEnd: TimeInterval
    let audioQueueEnd: TimeInterval

    static let empty = BunnyNativeMetricsSnapshot(
        decodedVideoFrames: 0,
        droppedVideoFrames: 0,
        renderedAudioFrames: 0,
        videoQueueEnd: .nan,
        audioQueueEnd: .nan
    )
}

/// Actual presentation diagnostics. Unlike `decodedVideoFrames`, these values
/// describe Apple's renderer, the source timestamp sequence, and the display
/// refresh loop rather than how quickly Bunny filled the input queue.
struct BunnyPresentationDiagnosticsSnapshot: Sendable {
    var rendererTotalFrames: Int?
    var rendererDroppedFrames: Int?
    var rendererCorruptedFrames: Int?
    var rendererFramesPerSecond: Double?
    var rendererAverageDelayMilliseconds: Double?
    var sourcePTSP95Milliseconds: Double?
    var sourcePTSMaximumMilliseconds: Double?
    var sourcePTSBackwardTransitions = 0
    var sourcePTSDuplicateTransitions = 0
    var sourcePTSOutlierTransitions = 0
    var sourceDTSP95Milliseconds: Double?
    var sourceDTSBackwardTransitions = 0
    var playbackClockRatio: Double?
    var appliedRate: Float = 0
    var displayRefreshHz: Double?
    var displayP95IntervalMilliseconds: Double?
    var displayMissedRefreshes = 0

    static let empty = BunnyPresentationDiagnosticsSnapshot()
}

struct BunnyHDRDiagnosticsSnapshot: Sendable {
    var inputBitsPerChannel: UInt32? = nil
    var inputPrimaries: UInt32? = nil
    var inputTransferCharacteristics: UInt32? = nil
    var inputMatrixCoefficients: UInt32? = nil
    var inputRange: UInt32? = nil
    var inputHasMasteringMetadata = false
    var inputHasContentLightLevel = false
    var inputDolbyVisionConfiguration: String? = nil
    var outputPixelFormat: String? = nil
    var outputColorPrimaries: String? = nil
    var outputTransferFunction: String? = nil
    var outputYCbCrMatrix: String? = nil
    var outputHasMasteringMetadata: Bool? = nil
    var outputHasContentLightLevel: Bool? = nil

    static let empty = BunnyHDRDiagnosticsSnapshot()
}

private struct BunnyDisplayCadenceSnapshot: Sendable {
    let refreshHz: Double?
    let p95IntervalMilliseconds: Double?
    let missedRefreshes: Int
}

/// A debug-only display-link observer. It never requests a refresh rate, so it
/// measures the system's current ProMotion/60 Hz cadence without influencing
/// playback. The sample-buffer renderer remains responsible for presentation.
private final class BunnyDisplayCadenceProbe: NSObject, @unchecked Sendable {
    private final class Target: NSObject {
        weak var owner: BunnyDisplayCadenceProbe?

        init(owner: BunnyDisplayCadenceProbe) {
            self.owner = owner
        }

        @objc func tick(_ displayLink: CADisplayLink) {
            owner?.record(displayLink)
        }
    }

    private let lock = NSLock()
    private let capacity = 360
    private var intervals: [TimeInterval] = []
    private var expectedIntervals: [TimeInterval] = []
    private var replacementIndex = 0
    private var previousTimestamp: TimeInterval?
    private var displayLink: CADisplayLink?
    private var target: Target?

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.displayLink == nil else { return }
            let target = Target(owner: self)
            let displayLink = CADisplayLink(
                target: target,
                selector: #selector(Target.tick(_:))
            )
            displayLink.add(to: .main, forMode: .common)
            self.target = target
            self.displayLink = displayLink
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
            self?.target = nil
        }
    }

    var snapshot: BunnyDisplayCadenceSnapshot {
        let samples = lock.withLock { (intervals, expectedIntervals) }
        let sorted = samples.0.filter { $0 > 0 }.sorted()
        let median = percentile(sorted, fraction: 0.50)
        let p95 = percentile(sorted, fraction: 0.95)
        let missed = zip(samples.0, samples.1).reduce(into: 0) { result, pair in
            guard pair.1 > 0, pair.0 > pair.1 * 1.5 else { return }
            let ratio = pair.0 / pair.1
            guard ratio.isFinite,
                  let roundedRefreshCount = Int(exactly: ratio.rounded())
            else {
                result = Int.max
                return
            }
            let missedForSample = max(roundedRefreshCount - 1, 1)
            let sum = result.addingReportingOverflow(missedForSample)
            result = sum.overflow ? Int.max : sum.partialValue
        }
        return BunnyDisplayCadenceSnapshot(
            refreshHz: median.map { 1 / $0 },
            p95IntervalMilliseconds: p95.map { $0 * 1_000 },
            missedRefreshes: missed
        )
    }

    private func record(_ displayLink: CADisplayLink) {
        let timestamp = displayLink.timestamp
        let expected = displayLink.targetTimestamp - displayLink.timestamp
        lock.withLock {
            defer { previousTimestamp = timestamp }
            guard let previousTimestamp else { return }
            let actual = timestamp - previousTimestamp
            guard actual > 0, actual < 1 else { return }
            if intervals.count < capacity {
                intervals.append(actual)
                expectedIntervals.append(expected)
            } else {
                intervals[replacementIndex] = actual
                expectedIntervals[replacementIndex] = expected
                replacementIndex = (replacementIndex + 1) % capacity
            }
        }
    }

    private func percentile(
        _ sorted: [TimeInterval],
        fraction: Double
    ) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

enum BunnyNativeDecoderError: LocalizedError {
    case invalidSource(String)
    case network(String)
    case unsupportedCodec(String)
    case formatDescription(String)
    case sampleBuffer(OSStatus)
    case core(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case let .invalidSource(message): "Bunny could not open this source: \(message)"
        case let .network(message): "Bunny could not read this source: \(message)"
        case let .unsupportedCodec(codec):
            "Bunny's native decoder does not yet support \(codec). Configure a streaming server for compatibility playback."
        case let .formatDescription(codec): "Bunny could not configure Apple's \(codec) decoder."
        case let .sampleBuffer(status): "Bunny could not create a media sample (\(status))."
        case let .core(message): "Bunny's Rust media core rejected this source: \(message)"
        case .stopped: "Playback stopped."
        }
    }
}


private struct BunnyNativeTrackDescriptor: @unchecked Sendable {
    let raw: StremioMediaTrackInfo
    let codecPrivate: Data
    let videoColor: StremioMediaVideoColorInfo
    let additionalCodecAtoms: [String: Data]
    let codecID: String
    let name: String
    let language: String
    let formatDescription: CMFormatDescription?
}

struct BunnyNativePacket: @unchecked Sendable {
    let trackIndex: Int
    let presentationTime: CMTime
    let decodeTime: CMTime
    let duration: CMTime
    let discardPadding: CMTime
    let flags: UInt32
    let data: Data
    let hdr10PlusData: Data?
}

private struct BunnyRawMediaPacket: @unchecked Sendable {
    let trackIndex: Int
    let presentationTimeNanoseconds: Int64
    let decodeTimeNanoseconds: Int64
    let durationNanoseconds: UInt64
    let discardPaddingNanoseconds: Int64
    let flags: UInt32
    let data: Data
    let hdr10PlusData: Data?
}

private enum BunnyPacketReadResult: @unchecked Sendable {
    case packet(BunnyRawMediaPacket)
    case endOfStream
    case failure(String)
}

private struct BunnyGenerationOwnedReadResult: @unchecked Sendable {
    let generation: UInt64
    let result: BunnyPacketReadResult
}

private struct BunnyPausedPacketRead: @unchecked Sendable {
    let result: BunnyPacketReadResult
    let wasInFlightWhenInterruptedForTrackSelection: Bool
}

/// Owns the one mutating Rust `next_packet` call independently from Bunny's
/// decode/presentation worker. The result inbox is single-slot and the caller
/// requests no more work while its compressed reservoir is full, so read-ahead
/// remains bounded without letting a progressive range read stall A/V pacing.
private final class BunnyPacketReadPump: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.temustremio.bunny-packet-read",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let session: OpaquePointer
    private var generation = 0
    private var active = true
    private var inFlight = false
    private var pendingResult: BunnyPacketReadResult?
    private var trackSelectionInterruptedGeneration: Int?

    init(session: OpaquePointer) {
        self.session = session
    }

    func requestRead() {
        let requestGeneration = lock.withLock { () -> Int? in
            guard active, !inFlight, pendingResult == nil else { return nil }
            inFlight = true
            return generation
        }
        guard let requestGeneration else { return }
        queue.async { [weak self] in
            self?.performRead(generation: requestGeneration)
        }
    }

    func takeResult() -> BunnyPacketReadResult? {
        lock.withLock {
            defer { pendingResult = nil }
            return pendingResult
        }
    }

    /// Marks the current read as owned by a deliberate track-selection
    /// interrupt before the range reader is cancelled. A result that had
    /// already completed remains ordinary source evidence.
    func pauseForTrackSelection() {
        lock.withLock {
            active = false
            guard inFlight else { return }
            trackSelectionInterruptedGeneration = generation
        }
    }

    /// The reader must be interrupted before this call when a seek or track
    /// selection needs exclusive access to the Rust session. A completed
    /// result is returned so a track-only change can retain packets belonging
    /// to unaffected tracks. Seeks and shutdown deliberately discard it via
    /// `pauseAndWait()`.
    func pauseAndTakeResult() -> BunnyPausedPacketRead? {
        lock.withLock {
            active = false
        }
        queue.sync {}
        return lock.withLock {
            let completedGeneration = generation
            generation &+= 1
            inFlight = false
            defer {
                pendingResult = nil
                trackSelectionInterruptedGeneration = nil
            }
            return pendingResult.map {
                BunnyPausedPacketRead(
                    result: $0,
                    wasInFlightWhenInterruptedForTrackSelection:
                        trackSelectionInterruptedGeneration == completedGeneration
                )
            }
        }
    }

    func pauseAndWait() {
        _ = pauseAndTakeResult()
    }

    func resume() {
        lock.withLock { active = true }
    }

    func stop() {
        pauseAndWait()
    }

    private func performRead(generation requestGeneration: Int) {
        var raw = StremioMediaPacket()
        var error = [CChar](repeating: 0, count: 512)
        let resultCode = error.withUnsafeMutableBufferPointer { errorBuffer in
            stremio_media_next_packet(
                session,
                &raw,
                errorBuffer.baseAddress,
                errorBuffer.count
            )
        }
        let result: BunnyPacketReadResult
        if resultCode == 0 {
            result = .endOfStream
        } else if resultCode == 1,
                  raw.abi_version == UInt32(STREMIO_MEDIA_PACKET_ABI_VERSION),
                  raw.data_size <= 16 * 1_024 * 1_024,
                  let bytes = raw.data {
            let hdr10PlusData: Data?
            if raw.hdr10_plus_data_size == 0 {
                hdr10PlusData = nil
            } else if raw.hdr10_plus_data_size <= 64 * 1_024,
                      let hdr10PlusBytes = raw.hdr10_plus_data {
                hdr10PlusData = Data(
                    bytes: hdr10PlusBytes,
                    count: raw.hdr10_plus_data_size
                )
            } else {
                hdr10PlusData = nil
            }
            result = .packet(BunnyRawMediaPacket(
                trackIndex: Int(raw.track_index),
                presentationTimeNanoseconds: raw.presentation_time_ns,
                decodeTimeNanoseconds: raw.decode_time_ns,
                durationNanoseconds: raw.duration_ns,
                discardPaddingNanoseconds: raw.discard_padding_ns,
                flags: raw.flags,
                data: Data(bytes: bytes, count: raw.data_size),
                hdr10PlusData: hdr10PlusData
            ))
        } else {
            let message = error.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress, base.pointee != 0 else {
                    return "media packet read failed"
                }
                return String(cString: base)
            }
            result = .failure(message)
        }
        lock.withLock {
            // `pauseAndTakeResult()` first prevents new work, then waits for
            // this queue. Keep a read that completed during that wait so an
            // unrelated audio/subtitle selection cannot consume and lose the
            // next video keyframe.
            guard requestGeneration == generation else { return }
            inFlight = false
            pendingResult = result
        }
    }
}

private final class BunnyVideoDecodeFrameContext: @unchecked Sendable {
    let generation: Int
    let submissionID: Int
    let shouldDisplay: Bool
    let decodeTime: TimeInterval

    init(
        generation: Int,
        submissionID: Int,
        shouldDisplay: Bool,
        decodeTime: TimeInterval
    ) {
        self.generation = generation
        self.submissionID = submissionID
        self.shouldDisplay = shouldDisplay
        self.decodeTime = decodeTime
    }
}

private struct BunnyDecodedVideoFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: CMTime
    let duration: CMTime
}

private struct BunnyVideoDecompressionDiagnostics: Sendable {
    let inFlightFrames: Int
    let readyFrames: Int
    let latestSubmittedDecodeTime: TimeInterval
    let earliestInFlightDecodeTime: TimeInterval?
    let maximumReorderLag: TimeInterval
    let firstReadyPresentationTime: TimeInterval?
    let lastDeliveredPresentationTime: TimeInterval
}

private struct BunnyVideoPresentationSnapshot: Sendable {
    let totalFrames: Int
    let framesSinceReset: Int
    let queueEnd: TimeInterval
}

private struct BunnyDecodedHDRSnapshot: Sendable {
    let pixelFormat: String
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let hasMasteringMetadata: Bool
    let hasContentLightLevel: Bool
}

/// VideoToolbox owns compressed-frame scheduling while Bunny owns the media
/// clock. Decoding before enqueueing avoids coupling a 4K decoder burst to the
/// display renderer's presentation deadline; the renderer only receives
/// uncompressed frames that are ready to present.
private final class BunnyVideoDecompressionPipeline: @unchecked Sendable {
    private static let maximumBufferedFrames = 24
    private static let minimumReorderSafetyDuration: TimeInterval = 0
    private static let outputCallback: VTDecompressionOutputCallback = {
        outputRefCon,
        sourceFrameRefCon,
        status,
        infoFlags,
        imageBuffer,
        presentationTime,
        presentationDuration in
        guard let outputRefCon, let sourceFrameRefCon else { return }
        let pipeline = Unmanaged<BunnyVideoDecompressionPipeline>
            .fromOpaque(outputRefCon)
            .takeUnretainedValue()
        let context = Unmanaged<BunnyVideoDecodeFrameContext>
            .fromOpaque(sourceFrameRefCon)
            .takeRetainedValue()
        pipeline.consume(
            context: context,
            status: status,
            infoFlags: infoFlags,
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            presentationDuration: presentationDuration
        )
    }

    private let formatDescription: CMVideoFormatDescription
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var generation = 0
    private var nextSubmissionID = 0
    private var inFlightFrames = 0
    private var inFlightDecodeTimes = [Int: TimeInterval]()
    private var readyFrames = [BunnyDecodedVideoFrame]()
    private var failureStatus: OSStatus?
    private var decoderDroppedFrames = 0
    private var lastDeliveredPresentationTime = -Double.infinity
    private var latestSubmittedDecodeTime = -Double.infinity
    private var maximumReorderLag = minimumReorderSafetyDuration
    private var acceptsAllReadyFrames = false
    private var reportedHDRDiagnostics = false
    private var decodedHDRSnapshot: BunnyDecodedHDRSnapshot?

    init(formatDescription: CMVideoFormatDescription) {
        self.formatDescription = formatDescription
    }

    deinit {
        invalidate()
    }

    var canAcceptMore: Bool {
        lock.withLock {
            failureStatus == nil
                && inFlightFrames + readyFrames.count < Self.maximumBufferedFrames
        }
    }

    var isDrained: Bool {
        lock.withLock { inFlightFrames == 0 && readyFrames.isEmpty }
    }

    var hasReadyFrames: Bool {
        lock.withLock { !readyFrames.isEmpty }
    }

    /// End of the contiguous decoded output that can be presented without
    /// overtaking either an unfinished callback or a future reordered packet.
    var deliverablePresentationEnd: TimeInterval? {
        lock.withLock {
            var end: TimeInterval?
            for frame in readyFrames {
                guard isDeliverableLocked(frame) else { break }
                let presentationTime = frame.presentationTime.seconds
                let duration = max(frame.duration.seconds, 0)
                guard presentationTime.isFinite else { continue }
                end = max(end ?? presentationTime, presentationTime + duration)
            }
            return end
        }
    }

    var droppedFrameCount: Int {
        lock.withLock { decoderDroppedFrames }
    }

    var failure: OSStatus? {
        lock.withLock { failureStatus }
    }

    var diagnosticsSnapshot: BunnyVideoDecompressionDiagnostics {
        lock.withLock {
            BunnyVideoDecompressionDiagnostics(
                inFlightFrames: inFlightFrames,
                readyFrames: readyFrames.count,
                latestSubmittedDecodeTime: latestSubmittedDecodeTime,
                earliestInFlightDecodeTime: earliestInFlightDecodeTimeLocked,
                maximumReorderLag: maximumReorderLag,
                firstReadyPresentationTime: readyFrames.first?.presentationTime.seconds,
                lastDeliveredPresentationTime: lastDeliveredPresentationTime
            )
        }
    }

    var hdrDiagnosticsSnapshot: BunnyDecodedHDRSnapshot? {
        lock.withLock { decodedHDRSnapshot }
    }

    func submit(
        _ sampleBuffer: CMSampleBuffer,
        shouldDisplay: Bool,
        decodeTime: TimeInterval,
        observedReorderLag: TimeInterval
    ) throws {
        let session = try decompressionSession()
        let contextValues = lock.withLock { () -> (generation: Int, submissionID: Int) in
            let submissionID = nextSubmissionID
            nextSubmissionID &+= 1
            inFlightFrames += 1
            inFlightDecodeTimes[submissionID] = decodeTime
            if decodeTime.isFinite {
                latestSubmittedDecodeTime = max(latestSubmittedDecodeTime, decodeTime)
            }
            if observedReorderLag.isFinite {
                maximumReorderLag = max(
                    maximumReorderLag,
                    max(observedReorderLag, 0)
                )
            }
            return (generation, submissionID)
        }
        let context = BunnyVideoDecodeFrameContext(
            generation: contextValues.generation,
            submissionID: contextValues.submissionID,
            shouldDisplay: shouldDisplay,
            decodeTime: decodeTime
        )
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        // Bunny reorders decoded output using the measured Matroska DTS/PTS
        // lag. Temporal processing would duplicate that work and permits
        // VideoToolbox to retain an entire GOP indefinitely.
        let decodeFlags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
        ]
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: contextPointer,
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            Unmanaged<BunnyVideoDecodeFrameContext>
                .fromOpaque(contextPointer)
                .release()
            lock.withLock {
                inFlightFrames = max(inFlightFrames - 1, 0)
                inFlightDecodeTimes.removeValue(forKey: contextValues.submissionID)
                failureStatus = status
            }
            NSLog("BUNNY_VT_SUBMIT_FAIL status=%d", status)
            throw BunnyNativeDecoderError.sampleBuffer(status)
        }
        if infoFlags.contains(.frameDropped) {
            lock.withLock { decoderDroppedFrames += 1 }
        }
    }

    func takeReadyFrame() -> BunnyDecodedVideoFrame? {
        lock.withLock {
            guard let first = readyFrames.first else { return nil }
            guard isDeliverableLocked(first) else { return nil }
            let presentationTime = first.presentationTime.seconds
            let frame = readyFrames.removeFirst()
            if presentationTime.isFinite {
                lastDeliveredPresentationTime = max(
                    lastDeliveredPresentationTime,
                    presentationTime
                )
            }
            return frame
        }
    }

    func finishDelayedFrames() {
        guard let session = lock.withLock({ self.session }) else { return }
        VTDecompressionSessionFinishDelayedFrames(session)
        lock.withLock { acceptsAllReadyFrames = true }
    }

    func reset() {
        let oldSession = lock.withLock { () -> VTDecompressionSession? in
            generation &+= 1
            readyFrames.removeAll(keepingCapacity: true)
            failureStatus = nil
            lastDeliveredPresentationTime = -Double.infinity
            latestSubmittedDecodeTime = -Double.infinity
            maximumReorderLag = Self.minimumReorderSafetyDuration
            acceptsAllReadyFrames = false
            inFlightDecodeTimes.removeAll(keepingCapacity: true)
            let oldSession = session
            session = nil
            return oldSession
        }
        guard let oldSession else { return }
        VTDecompressionSessionFinishDelayedFrames(oldSession)
        VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
        VTDecompressionSessionInvalidate(oldSession)
        lock.withLock {
            inFlightFrames = 0
            inFlightDecodeTimes.removeAll(keepingCapacity: true)
        }
    }

    func invalidate() {
        reset()
    }

    private func decompressionSession() throws -> VTDecompressionSession {
        if let existing = lock.withLock({ session }) { return existing }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var created: VTDecompressionSession?
        let decoderSpecification: CFDictionary?
        if #available(iOS 17.0, *) {
            decoderSpecification = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            ] as CFDictionary
        } else {
            decoderSpecification = nil
        }
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            let subtype = bunnyFourCC(
                CMFormatDescriptionGetMediaSubType(formatDescription)
            )
            let extensions = CMFormatDescriptionGetExtensions(formatDescription)
                .map { $0 as NSDictionary } ?? NSDictionary()
            let atoms = extensions[
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
            ] as? [String: Any]
            let atomSummary = atoms?.map { name, value in
                let size = (value as? Data)?.count ?? -1
                return "\(name):\(size)"
            }.sorted().joined(separator: ",") ?? "none"
            NSLog(
                "BUNNY_VT_CREATE_FAIL status=%d format=%@ atoms=%@",
                status,
                subtype,
                atomSummary
            )
            throw BunnyNativeDecoderError.sampleBuffer(status)
        }
        if #available(iOS 14.0, *) {
            let propagationStatus = VTSessionSetProperty(
                created,
                key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                value: kCFBooleanTrue
            )
            // Some Simulator decoders report the property as unsupported;
            // Apple's documented default is already true in that case.
            if propagationStatus != noErr,
               propagationStatus != kVTPropertyNotSupportedErr {
                NSLog("BUNNY_HDR_PROPAGATION_FAIL status=%d", propagationStatus)
            }
        }
        lock.withLock { session = created }
        return created
    }

    private func consume(
        context: BunnyVideoDecodeFrameContext,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTime: CMTime,
        presentationDuration: CMTime
    ) {
        // Keep this context in the in-flight watermark until its decoded frame
        // has actually been inserted. Removing it before sample construction
        // creates a race where the presentation pump can deliver a later PTS.
        let currentGeneration = lock.withLock { generation }
        guard context.generation == currentGeneration else { return }
        guard status == noErr else {
            complete(context) { failureStatus = status }
            NSLog(
                "BUNNY_VT_CALLBACK_FAIL status=%d dts=%.3f pts=%.3f",
                status,
                context.decodeTime,
                presentationTime.seconds
            )
            return
        }
        if infoFlags.contains(.frameDropped) {
            complete(context) { decoderDroppedFrames += 1 }
            return
        }
        guard context.shouldDisplay, let imageBuffer else {
            complete(context)
            return
        }

        var decodedFormat: CMVideoFormatDescription?
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: presentationDuration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &decodedFormat
        )
        let sampleStatus: OSStatus
        if formatStatus == noErr, let decodedFormat {
            sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: decodedFormat,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
        } else {
            sampleStatus = formatStatus
        }
        guard sampleStatus == noErr, let sampleBuffer else {
            complete(context) { failureStatus = sampleStatus }
            NSLog(
                "BUNNY_VT_SAMPLE_FAIL status=%d dts=%.3f pts=%.3f",
                sampleStatus,
                context.decodeTime,
                presentationTime.seconds
            )
            return
        }
        let shouldReportHDR = lock.withLock { () -> Bool in
            guard !reportedHDRDiagnostics else { return false }
            reportedHDRDiagnostics = true
            return true
        }
        if shouldReportHDR,
           let outputFormat = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let extensions = CMFormatDescriptionGetExtensions(outputFormat)
                .map { $0 as NSDictionary } ?? NSDictionary()
            let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
            let primaries = extensions[
                kCMFormatDescriptionExtension_ColorPrimaries as String
            ].map { String(describing: $0) } ?? "none"
            let transfer = extensions[
                kCMFormatDescriptionExtension_TransferFunction as String
            ].map { String(describing: $0) } ?? "none"
            let matrix = extensions[
                kCMFormatDescriptionExtension_YCbCrMatrix as String
            ].map { String(describing: $0) } ?? "none"
            let hasMastering = extensions[
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
            ] != nil
            let hasContentLight = extensions[
                kCMFormatDescriptionExtension_ContentLightLevelInfo as String
            ] != nil
            let snapshot = BunnyDecodedHDRSnapshot(
                pixelFormat: bunnyFourCC(pixelFormat),
                colorPrimaries: primaries == "none" ? nil : primaries,
                transferFunction: transfer == "none" ? nil : transfer,
                yCbCrMatrix: matrix == "none" ? nil : matrix,
                hasMasteringMetadata: hasMastering,
                hasContentLightLevel: hasContentLight
            )
            lock.withLock { decodedHDRSnapshot = snapshot }
            NSLog(
                "BUNNY_HDR_OUTPUT pixel_format=%@ primaries=%@ transfer=%@ matrix=%@ mdcv=%@ clli=%@",
                snapshot.pixelFormat,
                primaries,
                transfer,
                matrix,
                hasMastering ? "yes" : "no",
                hasContentLight ? "yes" : "no"
            )
        }
        let frame = BunnyDecodedVideoFrame(
            sampleBuffer: sampleBuffer,
            presentationTime: presentationTime,
            duration: presentationDuration
        )
        complete(context) {
            let presentationSeconds = presentationTime.seconds
            if presentationSeconds.isFinite,
               presentationSeconds + 0.000_5 < lastDeliveredPresentationTime {
                // A malformed or unexpectedly late output frame is unusable by
                // AVSampleBufferVideoRenderer, but it must not end playback.
                decoderDroppedFrames += 1
                NSLog(
                    "BUNNY_VT_REORDER_DROP dts=%.3f pts=%.3f last=%.3f lag=%.3f",
                    context.decodeTime,
                    presentationSeconds,
                    lastDeliveredPresentationTime,
                    maximumReorderLag
                )
                return
            }
            let insertionIndex = readyFrames.firstIndex {
                $0.presentationTime > presentationTime
            } ?? readyFrames.endIndex
            readyFrames.insert(frame, at: insertionIndex)
        }
    }

    private var earliestInFlightDecodeTimeLocked: TimeInterval? {
        guard !inFlightDecodeTimes.isEmpty else { return nil }
        // An invalid DTS cannot establish a safe presentation frontier. Hold
        // ready output until that callback completes rather than guessing.
        guard inFlightDecodeTimes.values.allSatisfy(\.isFinite) else {
            return -.infinity
        }
        return inFlightDecodeTimes.values.min()
    }

    private var safePresentationFrontierLocked: TimeInterval {
        // A newer asynchronous callback can complete before an older one.
        // Base the reorder watermark on the earliest decode that has not
        // completed yet so the presentation pump cannot overtake it.
        let decodeFrontier = earliestInFlightDecodeTimeLocked
            ?? latestSubmittedDecodeTime
        return decodeFrontier - maximumReorderLag
    }

    private func isDeliverableLocked(_ frame: BunnyDecodedVideoFrame) -> Bool {
        if acceptsAllReadyFrames, inFlightFrames == 0 { return true }
        let presentationTime = frame.presentationTime.seconds
        return !presentationTime.isFinite
            || presentationTime <= safePresentationFrontierLocked + 0.000_5
    }

    private func complete(
        _ context: BunnyVideoDecodeFrameContext,
        update: () -> Void = {}
    ) {
        lock.withLock {
            inFlightFrames = max(inFlightFrames - 1, 0)
            inFlightDecodeTimes.removeValue(forKey: context.submissionID)
            guard context.generation == generation else { return }
            update()
        }
    }
}

/// Drains decoded frames independently from the synchronous Rust range-read
/// callback. A slow HTTP read must not prevent already-decoded frames from
/// reaching Apple's small uncompressed renderer queue before their PTS.
private final class BunnyVideoPresentationPump: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.temustremio.bunny-video-presentation",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private let pipeline: BunnyVideoDecompressionPipeline
    private let rendererIsReady: () -> Bool
    private let enqueue: (CMSampleBuffer) -> Void
    private let onStateChanged: (BunnyVideoPresentationSnapshot, TimeInterval?) -> Void
    private var active = false
    private var suspended = false
    private var totalFrames = 0
    private var framesSinceReset = 0
    private var queueEnd: TimeInterval

    init(
        pipeline: BunnyVideoDecompressionPipeline,
        initialQueueEnd: TimeInterval,
        rendererIsReady: @escaping () -> Bool,
        enqueue: @escaping (CMSampleBuffer) -> Void,
        onStateChanged: @escaping (BunnyVideoPresentationSnapshot, TimeInterval?) -> Void
    ) {
        self.pipeline = pipeline
        queueEnd = initialQueueEnd
        self.rendererIsReady = rendererIsReady
        self.enqueue = enqueue
        self.onStateChanged = onStateChanged
    }

    var snapshot: BunnyVideoPresentationSnapshot {
        stateLock.withLock {
            BunnyVideoPresentationSnapshot(
                totalFrames: totalFrames,
                framesSinceReset: framesSinceReset,
                queueEnd: queueEnd
            )
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !active else { return }
            active = true
            drainOnce()
        }
    }

    func suspend() {
        queue.sync { suspended = true }
    }

    func reset(queueEnd: TimeInterval) {
        queue.sync {
            stateLock.withLock {
                framesSinceReset = 0
                self.queueEnd = queueEnd
            }
        }
    }

    func resume() {
        queue.sync { suspended = false }
    }

    func stop() {
        queue.sync { active = false }
    }

    private func drainOnce() {
        guard active else { return }
        if !suspended,
           rendererIsReady(),
           let frame = pipeline.takeReadyFrame() {
            enqueue(frame.sampleBuffer)
            let snapshot = stateLock.withLock { () -> BunnyVideoPresentationSnapshot in
                totalFrames += 1
                framesSinceReset += 1
                let frameEnd = frame.presentationTime.seconds
                    + max(frame.duration.seconds, 0)
                if frameEnd.isFinite {
                    queueEnd = max(queueEnd, frameEnd)
                }
                return BunnyVideoPresentationSnapshot(
                    totalFrames: totalFrames,
                    framesSinceReset: framesSinceReset,
                    queueEnd: queueEnd
                )
            }
            onStateChanged(snapshot, pipeline.deliverablePresentationEnd)
            queue.async { [weak self] in self?.drainOnce() }
        } else {
            onStateChanged(snapshot, pipeline.deliverablePresentationEnd)
            queue.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                self?.drainOnce()
            }
        }
    }

}

private enum BunnyNativeSubtitleDelivery: @unchecked Sendable {
    case text(String?, start: TimeInterval, duration: TimeInterval)
    case bitmap(
        BunnyNativeBitmapSubtitleCue?,
        start: TimeInterval,
        duration: TimeInterval?
    )
    case clearAll(at: TimeInterval)
}

private struct BunnyNativeSubtitleDeliveryEntry: @unchecked Sendable {
    let generation: UInt64
    let estimatedBytes: Int
    let delivery: BunnyNativeSubtitleDelivery
}

private struct BunnyNativeSubtitleDeliveryReservation: Sendable {
    let generation: UInt64
    let estimatedBytes: Int
}

private struct BunnyGenerationOwnedSeekRequest: Sendable {
    let request: BunnyNativeSeekRequest
    let subtitleDeliveryGeneration: UInt64
}

final class BunnyNativeDecoder: NSObject, @unchecked Sendable {
    let videoLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    var onOpen: (@MainActor (BunnyNativeMediaInfo) -> Void)?
    var onFirstFrame: (@MainActor () -> Void)?
    var onSubtitle: (@MainActor (String?, TimeInterval, TimeInterval) -> Void)?
    /// A nil duration is a stateful bitmap composition that remains visible
    /// until a later PGS composition explicitly replaces or clears it.
    var onBitmapSubtitle: (@MainActor (BunnyNativeBitmapSubtitleCue?, TimeInterval, TimeInterval?) -> Void)?
    var onSeekCompleted: (@MainActor (UInt64, TimeInterval, Bool) -> Void)?
    var onRecoverySeekCompleted: (@MainActor (UInt64?, BunnyNativeRecoverySeekReason, TimeInterval, Bool) -> Void)?
    var onMetrics: (@MainActor (Int, Int, Int, TimeInterval, TimeInterval, TimeInterval) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?

    var currentTime: TimeInterval {
        let seconds = synchronizer.currentTime().seconds
        let duration = stateLock.withLock { terminalPlaybackDuration ?? 0 }
        return PlaybackContinuityPolicy.clampedTimelinePosition(
            seconds,
            duration: duration
        )
    }

    var rate: Float {
        stateLock.withLock { desiredRate }
    }

    var hardwareVideoDecode: Bool {
        stateLock.withLock { firstFrameDelivered && hasVideo }
    }

    var hardwareVideoDecoderNegotiated: Bool {
        stateLock.withLock { videoFormatReady }
    }

    var metricsSnapshot: BunnyNativeMetricsSnapshot {
        stateLock.withLock { storedMetricsSnapshot }
    }

    var presentationDiagnosticsSnapshot: BunnyPresentationDiagnosticsSnapshot {
        var snapshot = stateLock.withLock { storedPresentationDiagnostics }
        if let display = displayCadenceProbe?.snapshot {
            snapshot.displayRefreshHz = display.refreshHz
            snapshot.displayP95IntervalMilliseconds = display.p95IntervalMilliseconds
            snapshot.displayMissedRefreshes = display.missedRefreshes
        }
        snapshot.appliedRate = synchronizer.rate
        return snapshot
    }

    var hdrDiagnosticsSnapshot: BunnyHDRDiagnosticsSnapshot {
        let values = stateLock.withLock {
            (storedHDRDiagnostics, activeVideoDecompression)
        }
        var snapshot = values.0
        if let decoded = values.1?.hdrDiagnosticsSnapshot {
            snapshot.outputPixelFormat = decoded.pixelFormat
            snapshot.outputColorPrimaries = decoded.colorPrimaries
            snapshot.outputTransferFunction = decoded.transferFunction
            snapshot.outputYCbCrMatrix = decoded.yCbCrMatrix
            snapshot.outputHasMasteringMetadata = decoded.hasMasteringMetadata
            snapshot.outputHasContentLightLevel = decoded.hasContentLightLevel
        }
        return snapshot
    }

    let prefersHardwareVideoDecoding = true

    var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    private let url: URL
    private let trustedPrivateNetworkOrigin: URL?
    private let worker = DispatchQueue(label: "app.temustremio.bunny-native", qos: .userInitiated)
    private let stateLock = NSLock()
    private let subtitleDeliveryLock = NSLock()
    private var subtitleDeliveryGeneration: UInt64 = 0
    private var pendingSubtitleDeliveries: [BunnyNativeSubtitleDeliveryEntry] = []
    private var pendingSubtitleDeliveryBytes = 0
    private var inFlightSubtitleDeliveryCount = 0
    private var inFlightSubtitleDeliveryBytes = 0
    private var reservedSubtitleDeliveryCount = 0
    private var reservedSubtitleDeliveryBytes = 0
    private var subtitleDeliveryDrainScheduled = false
    private var acceptsSubtitleDeliveries = true
    private var started = false
    private var stopped = false
    private var desiredRate: Float = 0
    private var terminalPlaybackDuration: TimeInterval?
    private var pendingSeek: BunnyGenerationOwnedSeekRequest?
    private var activeUserSeekRequestID: UInt64?
    private var activeAcknowledgedRecovery: BunnyNativeSeekRequest?
    private var pendingAudioSelection: Int?
    private var pendingSubtitleSelection: Int?
    private var pendingSubtitleSelectionGeneration: UInt64?
    private var selectedSubtitleStreamIndexSnapshot: Int?
    private var selectableSubtitleStreamIndices = Set<Int>()
    private var videoFormatReady = false
    private var firstFrameDelivered = false
    private var firstFrameCheckGeneration = 0
    private var firstFrameCheckScheduled = false
    private var hasVideo = false
    private var hasAudio = false
    private var decodedVideoBacklogEnd = -Double.infinity
    private var storedMetricsSnapshot = BunnyNativeMetricsSnapshot.empty
    private var storedPresentationDiagnostics = BunnyPresentationDiagnosticsSnapshot.empty
    private var storedHDRDiagnostics = BunnyHDRDiagnosticsSnapshot.empty
    private var activeVideoDecompression: BunnyVideoDecompressionPipeline?
    private var previousRendererMetrics: PlaybackRendererCumulativeMetrics?
    private var previousRendererMetricsAt: TimeInterval?
    private var rendererMetricsRequestInFlight = false
    private var rendererMetricsGeneration = 0
    private var activeReader: BunnyMediaRangeReader?
    private var activePacketReadPump: BunnyPacketReadPump?
    private var audioRendererFlushObserver: NSObjectProtocol?
    private let diagnosticsEnabled: Bool
    private let displayCadenceProbe: BunnyDisplayCadenceProbe?
    // Dolby layouts are encoded in the sync frame rather than Matroska's
    // channel-count field. This cache is confined to `worker`.
    private var dolbyFormatDescriptions: [Int: CMFormatDescription] = [:]
    private var reportedDolbyTimingMismatchTracks = Set<Int>()
    private var reportedHDR10PlusInput = false
    private static let maximumPendingSubtitleDeliveries = 128
    private static let maximumPendingSubtitleDeliveryBytes = 64 * 1_024 * 1_024
    private static let maximumPgsPresentationBytes = 32 * 1_024 * 1_024

    init(
        url: URL,
        trustedPrivateNetworkOrigin: URL? = nil,
        diagnosticsEnabled: Bool = false
    ) {
        let resolvedDiagnosticsEnabled = diagnosticsEnabled
            || ProcessInfo.processInfo.environment["SKELETON_PLAYER_DEBUG_OVERLAY"] == "1"
        self.url = url
        self.trustedPrivateNetworkOrigin = trustedPrivateNetworkOrigin
        self.diagnosticsEnabled = resolvedDiagnosticsEnabled
        displayCadenceProbe = resolvedDiagnosticsEnabled
            ? BunnyDisplayCadenceProbe()
            : nil
        super.init()
        videoLayer.videoGravity = .resizeAspect
        // Match the AVPlayer video default and the former player behavior.
        // AirPods users may enable Spatial Audio for stereo movies as well as
        // multichannel ones, so restricting this to `.multichannel` makes
        // stereo tracks sound noticeably narrower than the system player.
        if #available(iOS 15.0, *) {
            audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        }
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        // The queued renderers apply their own bounded backpressure. Waiting
        // for AVFoundation's larger "sufficient media" threshold here can
        // deadlock startup: the renderers stop accepting samples before the
        // synchronizer begins draining them.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        if #available(iOS 17.0, *) {
            // AVSampleBufferDisplayLayer's legacy queue methods are not safe
            // for Bunny's background demux worker. Its renderer is the
            // supported background enqueue surface and also exposes actual
            // presentation performance metrics on iOS 17.4 and newer.
            synchronizer.addRenderer(videoLayer.sampleBufferRenderer)
        } else {
            synchronizer.addRenderer(videoLayer)
        }
        synchronizer.addRenderer(audioRenderer)
        synchronizer.setRate(0, time: .zero)
        displayCadenceProbe?.start()
        audioRendererFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverAfterAutomaticAudioRendererFlush()
            }
        }
    }

    deinit {
        displayCadenceProbe?.stop()
        if let audioRendererFlushObserver {
            NotificationCenter.default.removeObserver(audioRendererFlushObserver)
        }
    }

    func start() {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        worker.async { [weak self] in self?.run() }
    }

    func play(atRate rate: Float) {
        let rate = min(max(rate, 0.25), 2)
        stateLock.withLock { desiredRate = rate }
        // The worker applies this intent once both enabled renderers have a
        // common reserve. Advancing the synchronizer immediately can outrun a
        // large remote source after startup or a seek.
    }

    func pause() {
        stateLock.withLock { desiredRate = 0 }
        guard PlaybackContinuityPolicy.requiresClockRateChange(
            currentRate: synchronizer.rate,
            requestedRate: 0
        ) else { return }
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    @MainActor
    func seek(to time: TimeInterval, requestID: UInt64) {
        guard requestID > 0 else { return }
        let displacedRecovery = stateLock.withLock { () -> BunnyNativeSeekRequest? in
            let displacedRecovery = activeAcknowledgedRecovery
            let subtitleGeneration = invalidateSubtitleDeliveries()
            terminalPlaybackDuration = nil
            pendingSeek = BunnyGenerationOwnedSeekRequest(
                request: BunnyNativeSeekRequest(
                    intent: .user(requestID: requestID),
                    targetTime: max(time, 0)
                ),
                subtitleDeliveryGeneration: subtitleGeneration
            )
            activeUserSeekRequestID = requestID
            // Publish the pending seek and suspend old-position reads under the
            // same lock so the worker cannot observe one without the other.
            activeReader?.interruptForSeek()
            return displacedRecovery
        }
        if let displacedRecovery {
            publishSeekCompletion(
                intent: displacedRecovery.intent,
                target: displacedRecovery.targetTime,
                succeeded: false
            )
        }
    }

    @discardableResult
    @MainActor
    func recoverFromTimedOutSeek(
        to time: TimeInterval,
        userRequestID: UInt64,
        recoveryRequestID: UInt64
    ) -> Bool {
        scheduleRecoverySeek(
            to: time,
            reason: .userSeekTimeout,
            recoveryRequestID: recoveryRequestID,
            replacingUserRequestID: userRequestID
        )
    }

    @discardableResult
    @MainActor
    func recoverFromFailedSeek(
        to time: TimeInterval,
        recoveryRequestID: UInt64
    ) -> Bool {
        scheduleRecoverySeek(
            to: time,
            reason: .userSeekFailure,
            recoveryRequestID: recoveryRequestID
        )
    }

    @MainActor
    private func recoverAfterAutomaticAudioRendererFlush() {
        let recoveryTime = currentTime
        let scheduled = scheduleRecoverySeek(
            to: recoveryTime,
            reason: .automaticAudioRendererFlush
        )
        guard scheduled else { return }
        NSLog(
            "BUNNY_AUDIO_RENDERER automatic_flush recovery_time=%.3f",
            recoveryTime
        )
    }

    @MainActor
    func selectAudioStreamIndex(_ streamIndex: Int) {
        stateLock.withLock {
            pendingAudioSelection = streamIndex
            activePacketReadPump?.pauseForTrackSelection()
            activeReader?.interruptForSeek()
        }
    }

    @MainActor
    func selectSubtitleStreamIndex(_ streamIndex: Int) {
        stateLock.withLock {
            let requestedStreamIndex = streamIndex >= 0 ? streamIndex : nil
            let pendingStreamIndex = pendingSubtitleSelection.flatMap {
                $0 >= 0 ? $0 : nil
            }
            guard PlaybackTrackSelectionPacketPolicy.shouldQueueSubtitleSelection(
                currentStreamIndex: selectedSubtitleStreamIndexSnapshot,
                hasPendingSelection: pendingSubtitleSelection != nil,
                pendingStreamIndex: pendingStreamIndex,
                requestedStreamIndex: requestedStreamIndex,
                selectableStreamIndices: selectableSubtitleStreamIndices
            ) else { return }
            pendingSubtitleSelectionGeneration = invalidateSubtitleDeliveries()
            pendingSubtitleSelection = streamIndex
            activePacketReadPump?.pauseForTrackSelection()
            activeReader?.interruptForSeek()
        }
    }

    func handleMemoryPressure() {
        let reader = stateLock.withLock { activeReader }
        DispatchQueue.global(qos: .utility).async {
            reader?.trimForMemoryPressure()
        }
    }

    @MainActor
    func stop() {
        invalidateSubtitleDeliveries(acceptingNewDeliveries: false)
        let reader = stateLock.withLock { () -> BunnyMediaRangeReader? in
            stopped = true
            desiredRate = 0
            firstFrameCheckGeneration &+= 1
            firstFrameCheckScheduled = false
            return activeReader
        }
        reader?.cancel()
        synchronizer.setRate(0, time: synchronizer.currentTime())
        flushVideoRenderer(removingDisplayedImage: true)
        audioRenderer.flush()
        displayCadenceProbe?.stop()
    }

    private func run() {
        var session: OpaquePointer?
        do {
            let reader = try BunnyMediaRangeReader(
                url: url,
                trustedPrivateNetworkOrigin: trustedPrivateNetworkOrigin,
                // Packet extraction runs on its own bounded pump. The playback
                // worker now owns underrun decisions from actual A/V coverage,
                // so a progressive network read must not pause the clock.
                onBlockingRead: { _ in false }
            )
            stateLock.withLock { activeReader = reader }
            defer {
                stateLock.withLock {
                    if activeReader === reader { activeReader = nil }
                }
            }
            let retainedReader = Unmanaged.passRetained(reader)
            defer { retainedReader.release() }
            let callbacks = StremioMediaSourceCallbacks(
                abi_version: 1,
                source_length: reader.sourceLength,
                read_at: bunnyNativeReadAt
            )
            var error = [CChar](repeating: 0, count: 512)
            session = error.withUnsafeMutableBufferPointer { errorBuffer in
                stremio_media_open_matroska(
                    callbacks,
                    retainedReader.toOpaque(),
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
            guard let session else {
                throw BunnyNativeDecoderError.core(Self.errorText(error))
            }
            defer { stremio_media_session_destroy(session) }
            guard let pgsDecoder = stremio_pgs_decoder_create() else {
                throw BunnyNativeDecoderError.core("could not create the PGS decoder")
            }
            defer { stremio_pgs_decoder_destroy(pgsDecoder) }

            var descriptors = try loadTracks(session: session)
            let summary = stremio_media_summary(session)
            guard summary.abi_version == UInt32(STREMIO_MEDIA_SUMMARY_ABI_VERSION) else {
                throw BunnyNativeDecoderError.core("unsupported media ABI")
            }
            var videoTracks = descriptors.filter {
                $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO)
                    && Self.isEnabled($0)
            }
            var playableVideoTracks = videoTracks.filter(Self.isApplePlayable)
            if playableVideoTracks.isEmpty,
               let candidate = Self.defaultTrack(
                    in: videoTracks.filter {
                        $0.raw.codec == UInt32(STREMIO_MEDIA_CODEC_HEVC)
                            && $0.formatDescription == nil
                    }
               ),
               let recoveredFormat = recoverInBandHEVCFormatDescription(
                    session: session,
                    descriptor: candidate,
                    error: &error
               ) {
                let recovered = BunnyNativeTrackDescriptor(
                    raw: candidate.raw,
                    codecPrivate: candidate.codecPrivate,
                    videoColor: candidate.videoColor,
                    additionalCodecAtoms: candidate.additionalCodecAtoms,
                    codecID: candidate.codecID,
                    name: candidate.name,
                    language: candidate.language,
                    formatDescription: recoveredFormat
                )
                descriptors[Int(candidate.raw.index)] = recovered
                videoTracks = descriptors.filter {
                    $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO)
                        && Self.isEnabled($0)
                }
                playableVideoTracks = videoTracks.filter(Self.isApplePlayable)
            }
            let audioTracks = descriptors.filter {
                $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO)
                    && Self.isEnabled($0)
            }
            let playableAudioTracks = audioTracks.filter(Self.isApplePlayable)
            let video = Self.defaultTrack(in: playableVideoTracks)
            let selectedAudio = Self.defaultTrack(in: playableAudioTracks)
            var selectedAudioStreamIndex = selectedAudio.map { Int($0.raw.index) }
            var selectedSubtitleStreamIndex: Int?
            if !videoTracks.isEmpty, video == nil {
                throw BunnyNativeDecoderError.unsupportedCodec(
                    videoTracks.map(\.codecID).joined(separator: ", ")
                )
            }
            let hasVideo = video != nil
            let hasAudio = selectedAudio != nil
            let nominalFrameRate = video.flatMap { descriptor in
                guard descriptor.raw.default_duration_ns > 0 else { return nil }
                return 1_000_000_000 / Double(descriptor.raw.default_duration_ns)
            } ?? 0
            stateLock.withLock {
                self.hasVideo = hasVideo
                self.hasAudio = hasAudio
                videoFormatReady = video?.formatDescription != nil
                storedHDRDiagnostics = video.map(Self.hdrInputDiagnostics)
                    ?? .empty
            }
            if let video {
                guard stremio_media_select_track(
                    session,
                    UInt32(STREMIO_MEDIA_TRACK_VIDEO),
                    Int32(video.raw.index)
                ) == 1 else {
                    throw BunnyNativeDecoderError.core("could not select the video track")
                }
            } else {
                _ = stremio_media_select_track(
                    session,
                    UInt32(STREMIO_MEDIA_TRACK_VIDEO),
                    -1
                )
            }
            if let selectedAudio {
                configureAudioRenderer(for: selectedAudio)
                guard stremio_media_select_track(
                    session,
                    UInt32(STREMIO_MEDIA_TRACK_AUDIO),
                    Int32(selectedAudio.raw.index)
                ) == 1 else {
                    throw BunnyNativeDecoderError.core("could not select the audio track")
                }
            } else {
                _ = stremio_media_select_track(
                    session,
                    UInt32(STREMIO_MEDIA_TRACK_AUDIO),
                    -1
                )
            }
            _ = stremio_media_select_track(
                session,
                UInt32(STREMIO_MEDIA_TRACK_SUBTITLE),
                -1
            )
            if !url.isFileURL, reader.sourceLength >= 40_000_000_000 {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let prepared = error.withUnsafeMutableBufferPointer { errorBuffer in
                    stremio_media_prepare_seek_index(
                        session,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
                let elapsedMilliseconds =
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                if prepared == 1 {
                    NSLog(
                        "BUNNY_SEEK_INDEX_READY bytes=%llu ms=%.1f",
                        reader.sourceLength,
                        elapsedMilliseconds
                    )
                } else {
                    // Playback remains available and a later seek retries the
                    // transactional deferred index load.
                    NSLog(
                        "BUNNY_SEEK_INDEX_DEFERRED bytes=%llu ms=%.1f error=%@",
                        reader.sourceLength,
                        elapsedMilliseconds,
                        Self.errorText(error)
                    )
                }
            }
            publishOpen(
                summary: summary,
                video: video,
                audio: playableAudioTracks,
                selectedAudio: selectedAudio,
                descriptors: descriptors
            )
            if video == nil {
                deliverFirstFrameOnce()
            }
            let videoDecompression: BunnyVideoDecompressionPipeline?
            if let videoFormat = video?.formatDescription {
                videoDecompression = BunnyVideoDecompressionPipeline(
                    formatDescription: videoFormat
                )
            } else {
                videoDecompression = nil
            }
            stateLock.withLock {
                activeVideoDecompression = videoDecompression
            }
            if hasVideo {
                NSLog("BUNNY_VIDEO_PIPELINE mode=explicit-videotoolbox")
            }
            let packetReadPump = BunnyPacketReadPump(session: session)
            stateLock.withLock { activePacketReadPump = packetReadPump }
            defer {
                stateLock.withLock {
                    if activePacketReadPump === packetReadPump {
                        activePacketReadPump = nil
                    }
                }
                reader.cancel()
                packetReadPump.stop()
            }

            var packetReservoir = BunnyNativePacketReservoir(
                width: Int(video?.raw.width ?? 0),
                height: Int(video?.raw.height ?? 0)
            )
            var videoTimingCalibrated = !hasVideo
            var calibratedVideoDecodeLead: TimeInterval = 0
            var videoQueueEnd = 0.0
            var audioQueueEnd = 0.0
            var decodedVideoFrames = 0
            var renderedAudioFrames = 0
            var droppedVideoFrames = 0
            var lastMetricsAt = ProcessInfo.processInfo.systemUptime
            var lastPresentationDiagnosticsAt = ProcessInfo.processInfo.systemUptime
            var lastVideoPipelineDiagnosticsAt = ProcessInfo.processInfo.systemUptime
            var lastPresentationClockTime = currentTime
            var sourceCadence = PlaybackTimestampCadenceTracker(
                nominalFrameRate: nominalFrameRate
            )
            var decodeCadence = PlaybackTimestampCadenceTracker(
                nominalFrameRate: nominalFrameRate
            )
            var reachedEnd = false
            var sourceExhausted = false
            var finishedDelayedVideoFrames = false
            var endPublished = false
            var seekTransition: BunnyNativeSeekTransition?
            var isRebuffering = true
            var lowReservePlaybackDeadline: TimeInterval = 0
            var requiresPostSeekPreroll = false
            var requiresCompressedPreroll = !url.isFileURL
            var isRefillingPacketReservoir = true
            var demuxGeneration: UInt64 = 0
            var deferredReadResult: BunnyGenerationOwnedReadResult?
            var activeSubtitleDeliveryGeneration = currentSubtitleDeliveryGeneration()
            let requiresFullRemotePreroll = !url.isFileURL
                && reader.sourceLength
                    >= PlaybackRangeChunkPolicy.largeSourceThresholdBytes
            var lastReservoirDiagnosticsAt = ProcessInfo.processInfo.systemUptime
            let videoPresentationPump = videoDecompression.map { pipeline in
                BunnyVideoPresentationPump(
                    pipeline: pipeline,
                    initialQueueEnd: videoQueueEnd,
                    rendererIsReady: { [weak self] in
                        self?.videoRendererIsReadyForMoreMediaData ?? false
                    },
                    enqueue: { [weak self] sample in
                        self?.enqueueVideoSample(sample)
                    },
                    onStateChanged: { [weak self] snapshot, backlogEnd in
                        self?.storeVideoPresentationSnapshot(
                            snapshot,
                            deliverableBacklogEnd: backlogEnd
                        )
                        if snapshot.framesSinceReset > 0 {
                            self?.scheduleFirstFrameCheck()
                        }
                    }
                )
            }
            videoPresentationPump?.start()
            defer {
                videoPresentationPump?.stop()
                videoDecompression?.invalidate()
                stateLock.withLock {
                    activeVideoDecompression = nil
                }
            }

            while !isStopped {
                if let generationOwnedSeek = takePendingSeek() {
                    let seekRequest = generationOwnedSeek.request
                    let seek = seekRequest.targetTime
                    demuxGeneration &+= 1
                    deferredReadResult = nil
                    packetReadPump.pauseAndWait()
                    reader.resumeAfterSeekInterrupt(prioritizeRandomAccess: true)
                    // A newer seek may have arrived after this one was taken.
                    // Leave its interruption in force and skip obsolete work.
                    if hasPendingSeek {
                        packetReadPump.resume()
                        continue
                    }
                    videoPresentationPump?.suspend()
                    videoDecompression?.reset()
                    finishedDelayedVideoFrames = false
                    let appliedSeekSubtitleGeneration =
                        PlaybackSubtitleDeliveryPolicy.generationAfterApplying(
                            currentAppliedGeneration:
                                activeSubtitleDeliveryGeneration,
                            mutationGeneration:
                                generationOwnedSeek.subtitleDeliveryGeneration
                        )
                    let success = performSeek(
                        session: session,
                        pgsDecoder: pgsDecoder,
                        time: seek,
                        subtitleDeliveryGeneration:
                            appliedSeekSubtitleGeneration,
                        error: &error
                    )
                    activeSubtitleDeliveryGeneration = appliedSeekSubtitleGeneration
                    packetReservoir.removeAll()
                    isRefillingPacketReservoir = true
                    videoQueueEnd = seek
                    videoPresentationPump?.reset(queueEnd: seek)
                    videoPresentationPump?.resume()
                    audioQueueEnd = seek
                    sourceCadence.reset()
                    decodeCadence.reset()
                    lastPresentationDiagnosticsAt = ProcessInfo.processInfo.systemUptime
                    lastPresentationClockTime = seek
                    isRebuffering = true
                    requiresPostSeekPreroll = false
                    storeMetricsSnapshot(
                        decodedVideoFrames: decodedVideoFrames,
                        droppedVideoFrames: droppedVideoFrames,
                        renderedAudioFrames: renderedAudioFrames,
                        videoQueueEnd: videoQueueEnd,
                        audioQueueEnd: audioQueueEnd
                    )
                    if success {
                        reachedEnd = false
                        sourceExhausted = false
                        endPublished = false
                        seekTransition = BunnyNativeSeekTransition(
                            intent: seekRequest.intent,
                            targetTime: seek,
                            hasVideo: hasVideo,
                            hasAudio: hasAudio
                        )
                        if completeSeekTransitionIfReady(&seekTransition) {
                            isRebuffering = false
                            requiresPostSeekPreroll = true
                            lowReservePlaybackDeadline =
                                ProcessInfo.processInfo.systemUptime + 0.25
                        }
                    } else {
                        seekTransition = nil
                        publishSeekCompletion(
                            intent: seekRequest.intent,
                            target: seek,
                            succeeded: false
                        )
                    }
                    packetReadPump.resume()
                }
                let selectionChanges: (
                    audio: Bool,
                    subtitle: Bool,
                    subtitleDeliveryGeneration: UInt64?
                )
                if hasPendingTrackSelection {
                    let pausedRead = packetReadPump.pauseAndTakeResult()
                    let completedReadResult = pausedRead?.result
                    reader.resumeAfterSeekInterrupt()
                    selectionChanges = applyPendingSelections(
                        session: session,
                        pgsDecoder: pgsDecoder,
                        descriptors: descriptors,
                        selectedAudioStreamIndex: &selectedAudioStreamIndex,
                        selectedSubtitleStreamIndex: &selectedSubtitleStreamIndex,
                        activeSubtitleDeliveryGeneration:
                            activeSubtitleDeliveryGeneration
                    )
                    if let generation = selectionChanges.subtitleDeliveryGeneration {
                        activeSubtitleDeliveryGeneration = generation
                    }
                    demuxGeneration &+= 1
                    if case let .packet(raw)? = completedReadResult,
                       let descriptor = descriptors[safe: raw.trackIndex],
                       PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                           kind: Self.packetTrackKind(descriptor.raw.kind),
                           audioSelectionChanged: selectionChanges.audio,
                           subtitleSelectionChanged: selectionChanges.subtitle
                       ) {
                        deferredReadResult = BunnyGenerationOwnedReadResult(
                            generation: demuxGeneration,
                            result: .packet(raw)
                        )
                    } else if case .endOfStream? = completedReadResult {
                        deferredReadResult = BunnyGenerationOwnedReadResult(
                            generation: demuxGeneration,
                            result: .endOfStream
                        )
                    } else if case let .failure(message)? = completedReadResult,
                              PlaybackTrackSelectionPacketPolicy
                                  .preservesCompletedReadFailure(
                                      readWasInFlightWhenInterruptedForTrackSelection:
                                          pausedRead?
                                              .wasInFlightWhenInterruptedForTrackSelection
                                              ?? false
                                  ) {
                        deferredReadResult = BunnyGenerationOwnedReadResult(
                            generation: demuxGeneration,
                            result: .failure(message)
                        )
                    }
                    packetReadPump.resume()
                } else {
                    selectionChanges = (
                        audio: false,
                        subtitle: false,
                        subtitleDeliveryGeneration: nil
                    )
                }
                if selectionChanges.audio {
                    packetReservoir.removeAll(kind: UInt32(STREMIO_MEDIA_TRACK_AUDIO))
                    isRefillingPacketReservoir = true
                    let reprimeTime = currentTime
                    let scheduledReprime = scheduleRecoverySeekFromWorker(
                        to: reprimeTime,
                        reason: .audioTrackSelection
                    )
                    NSLog(
                        "BUNNY_AUDIO_SWITCH action=%@ position=%.3f stream=%@",
                        scheduledReprime ? "reprime" : "coalesce_with_user_seek",
                        reprimeTime,
                        selectedAudioStreamIndex.map(String.init) ?? "none"
                    )
                    // Do not let the shared clock consume the stale audio
                    // queue bookkeeping for even one iteration. The pending
                    // seek rebuilds both renderers at this exact playhead.
                    continue
                }
                if selectionChanges.subtitle {
                    packetReservoir.removeAll(kind: UInt32(STREMIO_MEDIA_TRACK_SUBTITLE))
                    isRefillingPacketReservoir = true
                }
                let availableReadResult: BunnyPacketReadResult?
                if let completedReadResult = deferredReadResult {
                    availableReadResult = completedReadResult.generation == demuxGeneration
                        ? completedReadResult.result
                        : nil
                    deferredReadResult = nil
                } else {
                    availableReadResult = packetReadPump.takeResult()
                }
                if let readResult = availableReadResult {
                    switch readResult {
                    case let .packet(raw):
                        guard let descriptor = descriptors[safe: raw.trackIndex] else {
                            packetReadPump.requestRead()
                            continue
                        }
                        let packetDuration = effectivePacketDuration(
                            rawDurationNanoseconds: raw.durationNanoseconds,
                            trackIndex: raw.trackIndex,
                            data: raw.data,
                            descriptors: descriptors
                        )
                        let packet = BunnyNativePacket(
                            trackIndex: raw.trackIndex,
                            presentationTime: CMTime(
                                value: raw.presentationTimeNanoseconds,
                                timescale: 1_000_000_000
                            ),
                            decodeTime: CMTime(
                                value: raw.decodeTimeNanoseconds,
                                timescale: 1_000_000_000
                            ),
                            duration: packetDuration,
                            discardPadding: CMTime(
                                value: raw.discardPaddingNanoseconds,
                                timescale: 1_000_000_000
                            ),
                            flags: raw.flags,
                            data: raw.data,
                            hdr10PlusData: raw.hdr10PlusData
                        )
                        packetReservoir.append(packet, kind: descriptor.raw.kind)
                        if descriptor.raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO) {
                            sourceCadence.observe(
                                presentationTime: TimeInterval(
                                    raw.presentationTimeNanoseconds
                                ) / 1_000_000_000
                            )
                            decodeCadence.observe(
                                presentationTime: TimeInterval(
                                    raw.decodeTimeNanoseconds
                                ) / 1_000_000_000
                            )
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        if diagnosticsEnabled,
                           packetReservoir.packetCount > 0,
                           now - lastReservoirDiagnosticsAt >= 2 {
                            lastReservoirDiagnosticsAt = now
                            NSLog(
                                "BUNNY_PACKET_RESERVOIR state=filling packets=%d bytes=%d duration=%.3f",
                                packetReservoir.packetCount,
                                packetReservoir.byteCount,
                                packetReservoir.bufferedDuration
                            )
                        }
                    case .endOfStream:
                        sourceExhausted = true
                    case let .failure(message):
                        if hasPendingSeek || hasPendingTrackSelection { continue }
                        throw BunnyNativeDecoderError.core(message)
                    }
                }
                let wasRefillingPacketReservoir = isRefillingPacketReservoir
                isRefillingPacketReservoir = PlaybackCompressedPacketBufferPolicy
                    .shouldRefill(
                        isRefilling: isRefillingPacketReservoir,
                        byteCount: packetReservoir.byteCount,
                        packetCount: packetReservoir.packetCount,
                        bufferedDuration: packetReservoir.bufferedDuration,
                        limits: packetReservoir.limits
                    )
                if diagnosticsEnabled,
                   !wasRefillingPacketReservoir,
                   isRefillingPacketReservoir {
                    NSLog(
                        "BUNNY_PACKET_RESERVOIR state=refill_begin packets=%d bytes=%d duration=%.3f",
                        packetReservoir.packetCount,
                        packetReservoir.byteCount,
                        packetReservoir.bufferedDuration
                    )
                }
                if !sourceExhausted, isRefillingPacketReservoir {
                    packetReadPump.requestRead()
                }
                if let presentation = videoPresentationPump?.snapshot {
                    decodedVideoFrames = presentation.totalFrames
                    videoQueueEnd = presentation.queueEnd
                    if presentation.framesSinceReset > 0,
                       var transition = seekTransition {
                        transition.videoReady = true
                        seekTransition = transition
                        if completeSeekTransitionIfReady(&seekTransition) {
                            isRebuffering = false
                            requiresPostSeekPreroll = true
                            lowReservePlaybackDeadline =
                                ProcessInfo.processInfo.systemUptime + 0.25
                        }
                    }
                }

                if diagnosticsEnabled {
                    let diagnosticsNow = ProcessInfo.processInfo.systemUptime
                    let diagnosticsElapsed = diagnosticsNow - lastPresentationDiagnosticsAt
                    if diagnosticsElapsed >= 2 {
                        let clockTime = currentTime
                        let clockRatio = (clockTime - lastPresentationClockTime)
                            / diagnosticsElapsed
                        storeSourcePresentationDiagnostics(
                            sourceCadence.snapshot(),
                            decodeCadence: decodeCadence.snapshot(),
                            clockRatio: clockRatio.isFinite ? clockRatio : nil
                        )
                        lastPresentationDiagnosticsAt = diagnosticsNow
                        lastPresentationClockTime = clockTime
                        requestVideoPerformanceMetrics()
                    }
                }

                if reachedEnd {
                    updateAppliedPlaybackRate(
                        isRebuffering: &isRebuffering,
                        videoQueueEnd: videoQueueEnd,
                        audioQueueEnd: audioQueueEnd,
                        hasVideo: hasVideo,
                        hasAudio: hasAudio,
                        nominalFrameRate: nominalFrameRate,
                        allowsLowReservePlayback: false,
                        reachedEnd: true,
                        decodedVideoBacklogEnd: nil
                    )
                    let duration = TimeInterval(summary.duration_ns) / 1_000_000_000
                    let terminalDecision = PlaybackContinuityPolicy.terminalClockDecision(
                        sampledPosition: synchronizer.currentTime().seconds,
                        duration: duration,
                        continuingRate: stateLock.withLock { desiredRate }
                    )
                    if terminalDecision.shouldFinish, !endPublished {
                        endPublished = true
                        finishPlayback(
                            terminalDecision,
                            knownDuration: duration
                        )
                        publish { [weak self] in self?.onEnded?() }
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                let clock = currentTime
                let allowsLowReservePlayback = sourceExhausted
                    || ProcessInfo.processInfo.systemUptime < lowReservePlaybackDeadline
                if requiresPostSeekPreroll, !allowsLowReservePlayback {
                    // Advancing briefly releases hidden post-seek preroll
                    // samples. Once that bounded decoder grace expires, return
                    // to the normal 0.70-second preroll instead of continuing
                    // a large remote stream with only one or two frames queued.
                    isRebuffering = true
                    requiresPostSeekPreroll = false
                }
                if sourceExhausted {
                    if requiresCompressedPreroll {
                        requiresCompressedPreroll = false
                        NSLog("BUNNY_COMPRESSED_PREROLL state=eof_release")
                    }
                    if !videoTimingCalibrated {
                        calibratedVideoDecodeLead = PlaybackBufferingPolicy.videoDecodeLead(
                            maximumObservedLag: packetReservoir.maximumObservedVideoDecodeLag
                        )
                        videoTimingCalibrated = true
                        NSLog(
                            "BUNNY_VIDEO_TIMING_CALIBRATED mode=eof lead=%.6f lag=%.6f packets=%d",
                            calibratedVideoDecodeLead,
                            packetReservoir.maximumObservedVideoDecodeLag,
                            packetReservoir.observedVideoPacketCount
                        )
                    }
                }
                let compressedPrerollReady = !requiresCompressedPreroll
                    || PlaybackCompressedPacketBufferPolicy.hasRemotePreroll(
                        bufferedDuration: packetReservoir.bufferedDuration,
                        isFull: packetReservoir.isFull,
                        requiresFullBuffer: requiresFullRemotePreroll
                    )
                if compressedPrerollReady {
                    if requiresCompressedPreroll {
                        requiresCompressedPreroll = false
                        NSLog(
                            "BUNNY_COMPRESSED_PREROLL state=ready duration=%.3f bytes=%d packets=%d",
                            packetReservoir.bufferedDuration,
                            packetReservoir.byteCount,
                            packetReservoir.packetCount
                        )
                    }
                    updateAppliedPlaybackRate(
                        isRebuffering: &isRebuffering,
                        videoQueueEnd: videoQueueEnd,
                        audioQueueEnd: audioQueueEnd,
                        hasVideo: hasVideo,
                        hasAudio: hasAudio,
                        nominalFrameRate: nominalFrameRate,
                        allowsLowReservePlayback: allowsLowReservePlayback,
                        reachedEnd: false,
                        decodedVideoBacklogEnd:
                            videoDecompression?.deliverablePresentationEnd
                    )
                } else {
                    isRebuffering = true
                    if synchronizer.rate != 0 {
                        synchronizer.setRate(0, time: synchronizer.currentTime())
                    }
                }
                if videoRendererStatus == .failed {
                    throw videoRendererError
                        ?? BunnyNativeDecoderError.formatDescription(video?.codecID ?? "video")
                }
                if audioRenderer.status == .failed {
                    throw audioRenderer.error
                        ?? BunnyNativeDecoderError.formatDescription(selectedAudio?.codecID ?? "audio")
                }
                if let videoDecodeFailure = videoDecompression?.failure {
                    throw BunnyNativeDecoderError.sampleBuffer(videoDecodeFailure)
                }
                droppedVideoFrames = max(
                    droppedVideoFrames,
                    videoDecompression?.droppedFrameCount ?? 0
                )
                if diagnosticsEnabled,
                   ProcessInfo.processInfo.systemUptime
                    - lastVideoPipelineDiagnosticsAt >= 2,
                   let videoPipeline = videoDecompression?.diagnosticsSnapshot {
                    lastVideoPipelineDiagnosticsAt =
                        ProcessInfo.processInfo.systemUptime
                    NSLog(
                        "BUNNY_VT_STATE inflight=%d ready=%d latest_dts=%.3f earliest_inflight_dts=%@ reorder_lag=%.3f first_ready_pts=%@ last_delivered_pts=%.3f renderer_ready=%@ clock=%.3f video_end=%.3f audio_end=%.3f rate=%.2f",
                        videoPipeline.inFlightFrames,
                        videoPipeline.readyFrames,
                        videoPipeline.latestSubmittedDecodeTime,
                        Self.diagnosticNumber(
                            videoPipeline.earliestInFlightDecodeTime
                        ),
                        videoPipeline.maximumReorderLag,
                        Self.diagnosticNumber(
                            videoPipeline.firstReadyPresentationTime
                        ),
                        videoPipeline.lastDeliveredPresentationTime,
                        videoRendererIsReadyForMoreMediaData ? "yes" : "no",
                        currentTime,
                        videoQueueEnd,
                        audioQueueEnd,
                        synchronizer.rate
                    )
                }

                if !videoTimingCalibrated,
                   packetReservoir.videoTimingCalibrationReady {
                    calibratedVideoDecodeLead = PlaybackBufferingPolicy.videoDecodeLead(
                        maximumObservedLag: packetReservoir.maximumObservedVideoDecodeLag
                    )
                    videoTimingCalibrated = true
                    NSLog(
                        "BUNNY_VIDEO_TIMING_CALIBRATED lead=%.6f lag=%.6f packets=%d keyframes=%d span=%.3f",
                        calibratedVideoDecodeLead,
                        packetReservoir.maximumObservedVideoDecodeLag,
                        packetReservoir.observedVideoPacketCount,
                        packetReservoir.observedVideoKeyframeCount,
                        packetReservoir.observedVideoDecodeSpan
                    )
                }
                let maximumRendererLead = PlaybackBufferingPolicy.maximumRendererQueueLead
                let audioHasCapacity = !hasAudio
                    || audioQueueEnd - clock < maximumRendererLead
                let audioRendererCanAcceptPacket = PlaybackBufferingPolicy
                    .audioRendererCanAcceptPacket(
                        rendererIsReady: audioRenderer.isReadyForMoreMediaData,
                        hasPendingSeekTransition: seekTransition != nil
                    )
                let videoDecodeHasCapacity = !hasVideo
                    || (videoDecompression?.canAcceptMore ?? false)
                let subtitleReadyThrough = clock.isFinite ? clock + 12 : 12
                if sourceExhausted {
                    let discarded = packetReservoir.discardSubtitlePackets(
                        after: subtitleReadyThrough
                    )
                    if discarded.count > 0 {
                        NSLog(
                            "BUNNY_SUBTITLE_DROP codec=any packets=%d bytes=%d error=eof_horizon",
                            discarded.count,
                            discarded.bytes
                        )
                    }
                }
                let packet = packetReservoir.takeReady(
                    videoReady: compressedPrerollReady
                        && videoTimingCalibrated
                        && videoDecodeHasCapacity,
                    audioReady: compressedPrerollReady
                        && audioHasCapacity
                        && audioRendererCanAcceptPacket,
                    subtitleReadyThrough: subtitleReadyThrough
                )

                guard let packet else {
                    if sourceExhausted {
                        if packetReservoir.isEmpty {
                            if !finishedDelayedVideoFrames {
                                videoDecompression?.finishDelayedFrames()
                                finishedDelayedVideoFrames = true
                                Thread.sleep(forTimeInterval: 0.002)
                                continue
                            }
                            if videoDecompression?.isDrained == false {
                                Thread.sleep(forTimeInterval: 0.002)
                                continue
                            }
                            if let transition = seekTransition {
                                publishSeekCompletion(
                                    intent: transition.intent,
                                    target: transition.targetTime,
                                    succeeded: false
                                )
                                seekTransition = nil
                            }
                            reachedEnd = true
                        } else {
                            Thread.sleep(forTimeInterval: 0.002)
                        }
                        continue
                    }
                    if packetReservoir.isFull {
                        let discarded = packetReservoir
                            .discardBlockingFutureSubtitlePackets(
                                after: subtitleReadyThrough
                            )
                        if discarded.count > 0 {
                            isRefillingPacketReservoir = true
                            NSLog(
                                "BUNNY_SUBTITLE_DROP codec=any packets=%d bytes=%d error=refill_backpressure_horizon",
                                discarded.count,
                                discarded.bytes
                            )
                            packetReadPump.requestRead()
                            continue
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        if diagnosticsEnabled, now - lastReservoirDiagnosticsAt >= 2 {
                            lastReservoirDiagnosticsAt = now
                            NSLog(
                                "BUNNY_PACKET_RESERVOIR state=full packets=%d bytes=%d duration=%.3f",
                                packetReservoir.packetCount,
                                packetReservoir.byteCount,
                                packetReservoir.bufferedDuration
                            )
                        }
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }
                    packetReadPump.requestRead()
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                guard let descriptor = descriptors[safe: packet.trackIndex] else { continue }
                let presentationDisposition = PlaybackMediaPacketVisibilityPolicy
                    .disposition(
                        kind: Self.packetTrackKind(descriptor.raw.kind),
                        isInvisible: packet.flags
                            & UInt32(STREMIO_MEDIA_PACKET_INVISIBLE) != 0,
                        subtitleRequiresDecoderState: descriptor.raw.codec
                            == UInt32(STREMIO_MEDIA_CODEC_PGS)
                    )
                switch descriptor.raw.kind {
                case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
                    let isKeyframe = packet.flags & UInt32(STREMIO_MEDIA_PACKET_KEYFRAME) != 0
                    if diagnosticsEnabled, decodedVideoFrames < 72 {
                        NSLog(
                            "BUNNY_VIDEO_TIMING index=%d pts=%.6f source_dts=%.6f sample_dts=%.6f duration=%.6f key=%@",
                            decodedVideoFrames,
                            packet.presentationTime.seconds,
                            packet.decodeTime.seconds,
                            packet.decodeTime.seconds - calibratedVideoDecodeLead,
                            packet.duration.seconds,
                            isKeyframe ? "yes" : "no"
                        )
                    }
                    if var transition = seekTransition {
                        if PlaybackSeekTransitionPolicy.shouldDiscardVideoBeforeRandomAccessPoint(
                            isKeyframe: isKeyframe,
                            isWaitingForRandomAccessPoint: transition.isWaitingForVideoRandomAccessPoint
                        ) {
                            transition.discardedVideoPacketsBeforeRandomAccessPoint += 1
                            seekTransition = transition
                            continue
                        }
                        if isKeyframe {
                            transition.isWaitingForVideoRandomAccessPoint = false
                        }
                        seekTransition = transition
                    }
                    if videoRendererStatus == .failed {
                        throw videoRendererError
                            ?? BunnyNativeDecoderError.formatDescription(descriptor.codecID)
                    }
                    do {
                        let sample = try makeSampleBuffer(
                            packet: packet,
                            descriptor: descriptor,
                            videoDecodeLead: calibratedVideoDecodeLead
                        )
                        if !isKeyframe {
                            Self.setBooleanSampleAttachment(
                                sample,
                                key: kCMSampleAttachmentKey_NotSync
                            )
                        }
                        var shouldDisplay = presentationDisposition == .present
                        if !shouldDisplay {
                            Self.setBooleanSampleAttachment(
                                sample,
                                key: kCMSampleAttachmentKey_DoNotDisplay
                            )
                        }
                        if var transition = seekTransition {
                            let isPreroll = PlaybackSeekTransitionPolicy
                                .sampleIsEntirelyBeforeTarget(
                                    presentationTime: packet.presentationTime.seconds,
                                    duration: packet.duration.seconds,
                                    targetTime: transition.targetTime
                                )
                            if isPreroll {
                                Self.setBooleanSampleAttachment(
                                    sample,
                                    key: kCMSampleAttachmentKey_DoNotDisplay
                                )
                                transition.hiddenVideoFrames += 1
                                shouldDisplay = false
                            }
                            seekTransition = transition
                        }
                        guard let videoDecompression else {
                            throw BunnyNativeDecoderError.formatDescription(
                                descriptor.codecID
                            )
                        }
                        try videoDecompression.submit(
                            sample,
                            shouldDisplay: shouldDisplay,
                            decodeTime: packet.decodeTime.seconds,
                            observedReorderLag:
                                packetReservoir.maximumObservedVideoDecodeLag
                        )
                    } catch {
                        droppedVideoFrames += 1
                        throw error
                    }
                case UInt32(STREMIO_MEDIA_TRACK_AUDIO):
                    let sample = try makeSampleBuffer(
                        packet: packet,
                        descriptor: descriptor,
                        videoDecodeLead: 0
                    )
                    if presentationDisposition != .present {
                        Self.setBooleanSampleAttachment(
                            sample,
                            key: kCMSampleAttachmentKey_DoNotDisplay
                        )
                    }
                    if var transition = seekTransition {
                        let isPreroll = PlaybackSeekTransitionPolicy
                            .sampleIsEntirelyBeforeTarget(
                                presentationTime: packet.presentationTime.seconds,
                                duration: packet.duration.seconds,
                                targetTime: transition.targetTime
                            )
                        if isPreroll {
                            Self.setBooleanSampleAttachment(
                                sample,
                                key: kCMSampleAttachmentKey_DoNotDisplay
                            )
                            // Decode the selected track's SeekPreRoll history
                            // without presenting it. Stateful codecs such as
                            // Opus need this decoder history at the target.
                            audioRenderer.enqueue(sample)
                            transition.discardedAudioPackets += 1
                            seekTransition = transition
                            continue
                        }
                        transition.audioReady = true
                        seekTransition = transition
                    }
                    if audioRenderer.status == .failed {
                        throw audioRenderer.error
                            ?? BunnyNativeDecoderError.formatDescription(descriptor.codecID)
                    }
                    audioRenderer.enqueue(sample)
                    if presentationDisposition == .present {
                        renderedAudioFrames += 1
                    }
                    let end = packet.presentationTime.seconds + packet.duration.seconds
                    if end.isFinite { audioQueueEnd = max(audioQueueEnd, end) }
                    if completeSeekTransitionIfReady(&seekTransition) {
                        isRebuffering = false
                        requiresPostSeekPreroll = true
                        lowReservePlaybackDeadline =
                            ProcessInfo.processInfo.systemUptime + 0.25
                    }
                case UInt32(STREMIO_MEDIA_TRACK_SUBTITLE):
                    if descriptor.raw.codec == UInt32(STREMIO_MEDIA_CODEC_PGS) {
                        do {
                            try publishPgsPacket(
                                packet,
                                decoder: pgsDecoder,
                                subtitleDeliveryGeneration:
                                    activeSubtitleDeliveryGeneration,
                                shouldPublish: presentationDisposition == .present
                            )
                        } catch {
                            // A corrupt or non-conforming bitmap-subtitle
                            // block must not tear down otherwise healthy
                            // video and audio. Matroska stores each HDMV PGS
                            // segment in its own Block, so discard this Block
                            // and reset only subtitle assembly state. A later
                            // complete epoch can resume subtitle rendering.
                            stremio_pgs_decoder_reset(pgsDecoder)
                            if presentationDisposition == .present {
                                _ = enqueueSubtitleDelivery(
                                    .bitmap(
                                        nil,
                                        start: packet.presentationTime.seconds,
                                        duration: nil
                                    ),
                                    estimatedBytes: 0,
                                    generation: activeSubtitleDeliveryGeneration,
                                    priority: true
                                )
                            }
                            NSLog(
                                "BUNNY_SUBTITLE_DROP codec=PGS pts=%.3f bytes=%ld error=%@",
                                packet.presentationTime.seconds,
                                packet.data.count,
                                error.localizedDescription
                            )
                        }
                    } else if presentationDisposition == .present {
                        let text = Self.normalizedSubtitleText(
                            packet.data,
                            codec: descriptor.raw.codec
                        )
                        let queued = enqueueSubtitleDelivery(
                            .text(
                                text,
                                start: packet.presentationTime.seconds,
                                duration: max(packet.duration.seconds, 0.1)
                            ),
                            estimatedBytes: text == nil ? 0 : packet.data.count,
                            generation: activeSubtitleDeliveryGeneration,
                            priority: text == nil
                        )
                        if !queued {
                            NSLog(
                                "BUNNY_SUBTITLE_DROP codec=text pts=%.3f bytes=%ld error=callback_bound",
                                packet.presentationTime.seconds,
                                packet.data.count
                            )
                        }
                    }
                default:
                    break
                }
                storeMetricsSnapshot(
                    decodedVideoFrames: decodedVideoFrames,
                    droppedVideoFrames: droppedVideoFrames,
                    renderedAudioFrames: renderedAudioFrames,
                    videoQueueEnd: videoQueueEnd,
                    audioQueueEnd: audioQueueEnd
                )

                let now = ProcessInfo.processInfo.systemUptime
                if now - lastMetricsAt >= 0.25 {
                    lastMetricsAt = now
                    let metricsDecoded = decodedVideoFrames
                    let metricsDropped = droppedVideoFrames
                    let metricsAudio = renderedAudioFrames
                    let metricsVideoEnd = videoQueueEnd
                    let metricsAudioEnd = audioQueueEnd
                    let bufferedThrough: TimeInterval
                    if hasVideo, hasAudio {
                        bufferedThrough = min(metricsVideoEnd, metricsAudioEnd)
                    } else if hasVideo {
                        bufferedThrough = metricsVideoEnd
                    } else {
                        bufferedThrough = metricsAudioEnd
                    }
                    let buffered = max(bufferedThrough - currentTime, 0)
                    publish { [weak self] in
                        self?.onMetrics?(
                            metricsDecoded,
                            metricsDropped,
                            metricsAudio,
                            buffered,
                            metricsVideoEnd,
                            metricsAudioEnd
                        )
                    }
                }
            }
        } catch BunnyNativeDecoderError.stopped {
            return
        } catch {
            if isStopped { return }
            publish { [weak self] in self?.onFailure?(error) }
        }
    }

    private func loadTracks(session: OpaquePointer) throws -> [BunnyNativeTrackDescriptor] {
        let summary = stremio_media_summary(session)
        var result: [BunnyNativeTrackDescriptor] = []
        result.reserveCapacity(Int(summary.track_count))
        for index in 0..<summary.track_count {
            var raw = StremioMediaTrackInfo()
            guard stremio_media_track_info(session, index, &raw) == 1 else {
                throw BunnyNativeDecoderError.core("could not read track \(index)")
            }
            guard raw.abi_version == UInt32(STREMIO_MEDIA_TRACK_INFO_ABI_VERSION) else {
                throw BunnyNativeDecoderError.core(
                    "unsupported media track ABI for track \(index)"
                )
            }
            let codecID = Self.trackText(
                session: session,
                index: index,
                field: Int32(STREMIO_MEDIA_TRACK_TEXT_CODEC_ID)
            )
            let name = Self.trackText(
                session: session,
                index: index,
                field: Int32(STREMIO_MEDIA_TRACK_TEXT_NAME)
            )
            let language = Self.trackText(
                session: session,
                index: index,
                field: Int32(STREMIO_MEDIA_TRACK_TEXT_LANGUAGE)
            )
            var privateLength = 0
            let privatePointer = stremio_media_track_codec_private(session, index, &privateLength)
            let privateData = privatePointer.map { Data(bytes: $0, count: privateLength) } ?? Data()
            var videoColor = StremioMediaVideoColorInfo()
            if raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO) {
                guard stremio_media_track_video_color_info(
                    session,
                    index,
                    &videoColor
                ) == 1 else {
                    throw BunnyNativeDecoderError.core(
                        "could not read video color metadata for track \(index)"
                    )
                }
            }
            let additionalCodecAtoms = Self.blockAdditionCodecAtoms(
                session: session,
                trackIndex: index
            )
            let descriptor = BunnyNativeTrackDescriptor(
                raw: raw,
                codecPrivate: privateData,
                videoColor: videoColor,
                additionalCodecAtoms: additionalCodecAtoms,
                codecID: codecID,
                name: name,
                language: language,
                formatDescription: try makeFormatDescription(
                    raw: raw,
                    codecPrivate: privateData,
                    videoColor: videoColor,
                    additionalCodecAtoms: additionalCodecAtoms
                )
            )
            if raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO) {
                let atomNames = additionalCodecAtoms.keys.sorted().joined(separator: ",")
                let formatSubtype = descriptor.formatDescription.map {
                    bunnyFourCC(CMFormatDescriptionGetMediaSubType($0))
                } ?? "none"
                let hevcNALLength = raw.codec == UInt32(STREMIO_MEDIA_CODEC_HEVC)
                    && privateData.count > 21
                    ? Int((privateData[21] & 0x03) + 1)
                    : 0
                let hevcArrayCount = raw.codec == UInt32(STREMIO_MEDIA_CODEC_HEVC)
                    && privateData.count > 22
                    ? Int(privateData[22])
                    : 0
                NSLog(
                    "BUNNY_HDR_INPUT track=%u bits=%u primaries=%u transfer=%u matrix=%u range=%u mdcv=%@ clli=%@ atoms=%@ format=%@ private=%d nal_length=%d arrays=%d",
                    index,
                    videoColor.bits_per_channel,
                    videoColor.primaries,
                    videoColor.transfer_characteristics,
                    videoColor.matrix_coefficients,
                    videoColor.range,
                    videoColor.flags
                        & UInt32(STREMIO_MEDIA_VIDEO_COLOR_MASTERING_PRESENT) != 0
                        ? "yes" : "no",
                    videoColor.flags
                        & UInt32(STREMIO_MEDIA_VIDEO_COLOR_MAX_CLL_PRESENT) != 0
                        ? "yes" : "no",
                    atomNames.isEmpty ? "none" : atomNames,
                    formatSubtype,
                    privateData.count,
                    hevcNALLength,
                    hevcArrayCount
                )
            }
            result.append(descriptor)
        }
        return result
    }

    private func recoverInBandHEVCFormatDescription(
        session: OpaquePointer,
        descriptor: BunnyNativeTrackDescriptor,
        error: inout [CChar]
    ) -> CMVideoFormatDescription? {
        guard stremio_media_select_track(
            session,
            UInt32(STREMIO_MEDIA_TRACK_VIDEO),
            Int32(descriptor.raw.index)
        ) == 1 else { return nil }
        _ = stremio_media_select_track(
            session,
            UInt32(STREMIO_MEDIA_TRACK_AUDIO),
            -1
        )
        _ = stremio_media_select_track(
            session,
            UInt32(STREMIO_MEDIA_TRACK_SUBTITLE),
            -1
        )

        let preferredLengthFieldBytes = descriptor.codecPrivate.count > 21
            ? Int((descriptor.codecPrivate[21] & 0x03) + 1)
            : 4
        var parameterSets = [UInt8: Data]()
        var recoveredHeaderLength: Int32 = Int32(preferredLengthFieldBytes)
        var inspectedPackets = 0
        var inspectedBytes = 0
        while inspectedPackets < 96, inspectedBytes < 32 * 1_024 * 1_024 {
            var packet = StremioMediaPacket()
            let result = error.withUnsafeMutableBufferPointer { errorBuffer in
                stremio_media_next_packet(
                    session,
                    &packet,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
            guard result == 1,
                  packet.abi_version == UInt32(STREMIO_MEDIA_PACKET_ABI_VERSION),
                  packet.track_index == descriptor.raw.index,
                  packet.data_size <= 16 * 1_024 * 1_024,
                  let bytes = packet.data
            else { break }
            let data = Data(bytes: bytes, count: packet.data_size)
            inspectedPackets += 1
            inspectedBytes += data.count
            if let parsed = hevcParameterSetsInPacket(
                data,
                preferredLengthFieldBytes: preferredLengthFieldBytes
            ) {
                recoveredHeaderLength = parsed.nalUnitHeaderLength
                for parameterSet in parsed.parameterSets {
                    guard let first = parameterSet.first else { continue }
                    parameterSets[(first >> 1) & 0x3f] = parameterSet
                }
            }
            if parameterSets[32] != nil,
               parameterSets[33] != nil,
               parameterSets[34] != nil {
                break
            }
        }

        let rewound = error.withUnsafeMutableBufferPointer { errorBuffer in
            stremio_media_rewind(
                session,
                errorBuffer.baseAddress,
                errorBuffer.count
            )
        }
        guard rewound == 1 else {
            NSLog("BUNNY_HEVC_INBAND_RECOVERY rewind=failed")
            return nil
        }
        guard let vps = parameterSets[32],
              let sps = parameterSets[33],
              let pps = parameterSets[34],
              let format = makeHEVCFormatDescription(
                parameterSets: [vps, sps, pps],
                nalUnitHeaderLength: recoveredHeaderLength,
                color: descriptor.videoColor,
                additionalCodecAtoms: descriptor.additionalCodecAtoms,
                track: descriptor.raw
              ),
              videoFormatSupportsDecompression(format)
        else {
            NSLog(
                "BUNNY_HEVC_INBAND_RECOVERY result=failed packets=%d bytes=%d sets=%d",
                inspectedPackets,
                inspectedBytes,
                parameterSets.count
            )
            return nil
        }
        NSLog(
            "BUNNY_HEVC_INBAND_RECOVERY result=ready packets=%d bytes=%d nal_length=%d",
            inspectedPackets,
            inspectedBytes,
            recoveredHeaderLength
        )
        return format
    }

    private static func blockAdditionCodecAtoms(
        session: OpaquePointer,
        trackIndex: UInt32
    ) -> [String: Data] {
        let count = stremio_media_track_block_addition_mapping_count(
            session,
            trackIndex
        )
        guard count > 0, count <= 64 else { return [:] }
        var atoms = [String: Data]()
        for mappingIndex in 0..<count {
            var mapping = StremioMediaBlockAdditionMappingInfo()
            guard stremio_media_track_block_addition_mapping_info(
                session,
                trackIndex,
                mappingIndex,
                &mapping
            ) == 1,
            mapping.extra_data_size > 0,
            mapping.extra_data_size <= 16 * 1_024 * 1_024,
            let bytes = mapping.extra_data
            else { continue }
            let atomName: String? = switch mapping.id_type {
            case UInt64(STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_DVCC): "dvcC"
            case UInt64(STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_DVVC): "dvvC"
            case UInt64(STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_DVWC): "dvwC"
            case UInt64(STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_HVCE): "hvcE"
            default: nil
            }
            if let atomName {
                atoms[atomName] = Data(
                    bytes: bytes,
                    count: mapping.extra_data_size
                )
            }
        }
        return atoms
    }

    private func publishOpen(
        summary: StremioMediaSummary,
        video: BunnyNativeTrackDescriptor?,
        audio: [BunnyNativeTrackDescriptor],
        selectedAudio: BunnyNativeTrackDescriptor?,
        descriptors: [BunnyNativeTrackDescriptor]
    ) {
        let subtitles = descriptors.filter {
            $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_SUBTITLE)
                && Self.isSelectableSubtitle($0)
        }
        stateLock.withLock {
            selectableSubtitleStreamIndices = Set(
                subtitles.map { Int($0.raw.index) }
            )
            selectedSubtitleStreamIndexSnapshot = nil
        }
        let info = BunnyNativeMediaInfo(
            duration: TimeInterval(summary.duration_ns) / 1_000_000_000,
            presentationSize: video.map(Self.presentationSize) ?? .zero,
            nominalFrameRate: video.flatMap { descriptor in
                guard descriptor.raw.default_duration_ns > 0 else { return nil }
                return 1_000_000_000 / Double(descriptor.raw.default_duration_ns)
            } ?? 0,
            hasVideo: video != nil,
            hasAudio: !audio.isEmpty,
            containerName: summary.container_kind == 2 ? "WebM" : "Matroska",
            videoCodecName: video.map(\.codecID),
            audioCodecName: selectedAudio.map(\.codecID),
            audioTracks: audio.map(Self.presentationTrack),
            subtitleTracks: subtitles.map(Self.presentationTrack),
            selectedAudioStreamIndex: Int(selectedAudio?.raw.index ?? UInt32.max),
            selectedSubtitleStreamIndex: -1
        )
        publish { [weak self] in
            PlaybackAudioSession.configurePlaybackContent(
                channelCount: selectedAudio.map { Int($0.raw.channels) } ?? 2
            )
            self?.onOpen?(info)
        }
    }

    private func applyPendingSelections(
        session: OpaquePointer,
        pgsDecoder: OpaquePointer,
        descriptors: [BunnyNativeTrackDescriptor],
        selectedAudioStreamIndex: inout Int?,
        selectedSubtitleStreamIndex: inout Int?,
        activeSubtitleDeliveryGeneration: UInt64
    ) -> (
        audio: Bool,
        subtitle: Bool,
        subtitleDeliveryGeneration: UInt64?
    ) {
        let selections = stateLock.withLock {
            () -> (audio: Int?, subtitle: Int?, generation: UInt64?) in
            defer {
                pendingAudioSelection = nil
                pendingSubtitleSelection = nil
                pendingSubtitleSelectionGeneration = nil
            }
            return (
                pendingAudioSelection,
                pendingSubtitleSelection,
                pendingSubtitleSelectionGeneration
            )
        }
        guard selections.audio != nil || selections.subtitle != nil else {
            return (
                audio: false,
                subtitle: false,
                subtitleDeliveryGeneration: nil
            )
        }
        var audioChanged = false
        var subtitleChanged = false
        let appliedSubtitleDeliveryGeneration = selections.generation.map {
            PlaybackSubtitleDeliveryPolicy.generationAfterApplying(
                currentAppliedGeneration: activeSubtitleDeliveryGeneration,
                mutationGeneration: $0
            )
        }
        if let audio = selections.audio {
            if !PlaybackTrackSelectionPacketPolicy.requiresAudioTimelineReprime(
                currentStreamIndex: selectedAudioStreamIndex,
                requestedStreamIndex: audio
            ) {
                NSLog("BUNNY_AUDIO_SWITCH action=noop stream=%ld", audio)
            } else if let descriptor = descriptors.first(where: {
                Int($0.raw.index) == audio && Self.isApplePlayable($0)
            }), stremio_media_select_track(
                session,
                UInt32(STREMIO_MEDIA_TRACK_AUDIO),
                Int32(audio)
            ) == 1 {
                audioChanged = true
                selectedAudioStreamIndex = audio
                audioRenderer.flush()
                configureAudioRenderer(for: descriptor)
                publish {
                    PlaybackAudioSession.configurePlaybackContent(
                        channelCount: Int(descriptor.raw.channels)
                    )
                }
            }
        }
        if let subtitle = selections.subtitle {
            let requestedSubtitleStreamIndex = subtitle >= 0 ? subtitle : nil
            if requestedSubtitleStreamIndex == selectedSubtitleStreamIndex {
                NSLog("BUNNY_SUBTITLE_SWITCH action=noop stream=%ld", subtitle)
            } else if requestedSubtitleStreamIndex == nil
                        || descriptors.contains(where: {
                            Int($0.raw.index) == subtitle
                                && Self.isSelectableSubtitle($0)
                        }) {
                subtitleChanged = stremio_media_select_track(
                    session,
                    UInt32(STREMIO_MEDIA_TRACK_SUBTITLE),
                    Int32(subtitle)
                ) == 1
                if subtitleChanged {
                    selectedSubtitleStreamIndex = requestedSubtitleStreamIndex
                    stateLock.withLock {
                        selectedSubtitleStreamIndexSnapshot =
                            requestedSubtitleStreamIndex
                    }
                    stremio_pgs_decoder_reset(pgsDecoder)
                    let clearTime = currentTime
                    if let generation = appliedSubtitleDeliveryGeneration {
                        _ = enqueueSubtitleDelivery(
                            .clearAll(at: clearTime),
                            estimatedBytes: 0,
                            generation: generation,
                            priority: true
                        )
                    }
                }
            }
        }
        return (
            audio: audioChanged,
            subtitle: subtitleChanged,
            subtitleDeliveryGeneration: selections.subtitle == nil
                ? nil
                : appliedSubtitleDeliveryGeneration
        )
    }

    private func configureAudioRenderer(for descriptor: BunnyNativeTrackDescriptor) {
        let multichannel = descriptor.raw.channels > 2
        // Apple's time-domain algorithm is the AVSampleBufferAudioRenderer
        // default and avoids unnecessary spectral processing for mono/stereo.
        // Multichannel tracks retain the spectral path used by the legacy
        // player when playback speed changes.
        audioRenderer.audioTimePitchAlgorithm = multichannel ? .spectral : .timeDomain
        NSLog(
            "BUNNY_AUDIO_POLICY codec=%@ channels=%u spatialization=mono_stereo_multichannel time_pitch=%@",
            descriptor.codecID,
            descriptor.raw.channels,
            multichannel ? "spectral" : "time_domain"
        )
    }

    private func effectivePacketDuration(
        rawDurationNanoseconds: UInt64,
        trackIndex: Int,
        data: Data,
        descriptors: [BunnyNativeTrackDescriptor]
    ) -> CMTime {
        let containerDuration = CMTime(
            value: Int64(clamping: rawDurationNanoseconds),
            timescale: 1_000_000_000
        )
        guard let descriptor = descriptors[safe: trackIndex],
              descriptor.raw.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO),
              descriptor.raw.codec == UInt32(STREMIO_MEDIA_CODEC_AC3)
                || descriptor.raw.codec == UInt32(STREMIO_MEDIA_CODEC_EAC3),
              descriptor.raw.sample_rate.isFinite,
              descriptor.raw.sample_rate > 0
        else { return containerDuration }

        let sampleFrames = data.withUnsafeBytes { bytes in
            stremio_media_dolby_sample_frames(
                descriptor.raw.codec,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard sampleFrames > 0 else { return containerDuration }
        let bitstreamDuration = CMTime(
            seconds: Double(sampleFrames) / descriptor.raw.sample_rate,
            preferredTimescale: 1_000_000_000
        )
        let delta = abs(containerDuration.seconds - bitstreamDuration.seconds)
        if (!containerDuration.isValid || containerDuration <= .zero || delta > 0.0005),
           reportedDolbyTimingMismatchTracks.insert(trackIndex).inserted {
            NSLog(
                "BUNNY_AUDIO_TIMING codec=%@ track=%ld container_ms=%.3f bitstream_ms=%.3f sample_frames=%u source=bitstream",
                descriptor.codecID,
                trackIndex,
                containerDuration.seconds * 1_000,
                bitstreamDuration.seconds * 1_000,
                sampleFrames
            )
        }
        // The sync frame is authoritative. E-AC-3 can contain 1, 2, 3, or 6
        // blocks, so assuming 1,536 frames is incorrect for valid streams.
        return bitstreamDuration
    }

    private var videoRendererStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(iOS 17.0, *) {
            return videoLayer.sampleBufferRenderer.status
        }
        return videoLayer.status
    }

    private var videoRendererError: Error? {
        if #available(iOS 17.0, *) {
            return videoLayer.sampleBufferRenderer.error
        }
        return videoLayer.error
    }

    private var videoRendererIsReadyForMoreMediaData: Bool {
        if #available(iOS 17.0, *) {
            return videoLayer.sampleBufferRenderer.isReadyForMoreMediaData
        }
        return videoLayer.isReadyForMoreMediaData
    }

    private func enqueueVideoSample(_ sample: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.enqueue(sample)
        } else {
            videoLayer.enqueue(sample)
        }
    }

    private func flushVideoRenderer(removingDisplayedImage: Bool) {
        stateLock.withLock {
            rendererMetricsGeneration &+= 1
            previousRendererMetrics = nil
            previousRendererMetricsAt = nil
            storedPresentationDiagnostics.rendererFramesPerSecond = nil
            storedPresentationDiagnostics.rendererAverageDelayMilliseconds = nil
        }
        if #available(iOS 17.0, *) {
            if removingDisplayedImage {
                videoLayer.sampleBufferRenderer.flush(
                    removingDisplayedImage: true,
                    completionHandler: nil
                )
            } else {
                videoLayer.sampleBufferRenderer.flush()
            }
        } else if removingDisplayedImage {
            videoLayer.flushAndRemoveImage()
        } else {
            videoLayer.flush()
        }
    }

    private func performSeek(
        session: OpaquePointer,
        pgsDecoder: OpaquePointer,
        time: TimeInterval,
        subtitleDeliveryGeneration: UInt64,
        error: inout [CChar]
    ) -> Bool {
        let boundedTime = max(time, 0)
        guard boundedTime.isFinite,
              let nanoseconds = UInt64(
                exactly: (boundedTime * 1_000_000_000).rounded()
              )
        else { return false }
        _ = enqueueSubtitleDelivery(
            .clearAll(at: boundedTime),
            estimatedBytes: 0,
            generation: subtitleDeliveryGeneration,
            priority: true
        )
        synchronizer.setRate(
            0,
            time: CMTime(seconds: boundedTime, preferredTimescale: 1_000_000_000)
        )
        // Keep the last clean frame visible while the decoder reconstructs
        // references from the preceding keyframe. Preroll samples are decoded
        // with DoNotDisplay, then the first frame covering the target replaces
        // this image without exposing a fast-forward catch-up sequence.
        flushVideoRenderer(removingDisplayedImage: false)
        audioRenderer.flush()
        stremio_pgs_decoder_reset(pgsDecoder)
        stateLock.withLock {
            firstFrameDelivered = false
            firstFrameCheckGeneration &+= 1
            firstFrameCheckScheduled = false
        }
        let result = error.withUnsafeMutableBufferPointer { errorBuffer in
            stremio_media_seek(
                session,
                nanoseconds,
                errorBuffer.baseAddress,
                errorBuffer.count
            )
        }
        return result == 1
    }

    private func finishPlayback(
        _ decision: PlaybackTerminalClockDecision,
        knownDuration duration: TimeInterval
    ) {
        let knownDuration = duration.isFinite && duration > 0 ? duration : nil
        stateLock.withLock {
            desiredRate = decision.desiredRate
            terminalPlaybackDuration = knownDuration
        }
        synchronizer.setRate(
            decision.appliedRate,
            time: CMTime(
                seconds: decision.position,
                preferredTimescale: 1_000_000_000
            )
        )
    }

    private func updateAppliedPlaybackRate(
        isRebuffering: inout Bool,
        videoQueueEnd: TimeInterval,
        audioQueueEnd: TimeInterval,
        hasVideo: Bool,
        hasAudio: Bool,
        nominalFrameRate: Double,
        allowsLowReservePlayback: Bool,
        reachedEnd: Bool,
        decodedVideoBacklogEnd: TimeInterval?
    ) {
        let desiredRate = stateLock.withLock { self.desiredRate }
        let previousRebuffering = isRebuffering
        let clock = currentTime
        let decision = PlaybackBufferingPolicy.decision(
            desiredRate: desiredRate,
            isRebuffering: isRebuffering,
            clock: clock,
            videoQueueEnd: videoQueueEnd,
            audioQueueEnd: audioQueueEnd,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            nominalFrameRate: nominalFrameRate,
            allowsLowReservePlayback: allowsLowReservePlayback,
            reachedEnd: reachedEnd,
            requiredResumeReserve: decodedVideoBacklogEnd == nil
                ? PlaybackBufferingPolicy.resumeReserve
                : PlaybackBufferingPolicy.predecodedVideoResumeReserve,
            decodedVideoBacklogEnd: decodedVideoBacklogEnd
        )
        isRebuffering = decision.isRebuffering
        if PlaybackContinuityPolicy.requiresClockRateChange(
            currentRate: synchronizer.rate,
            requestedRate: decision.appliedRate
        ) {
            synchronizer.setRate(decision.appliedRate, time: synchronizer.currentTime())
        }
        if previousRebuffering != decision.isRebuffering, desiredRate > 0 {
            let effectiveVideoQueueEnd = PlaybackBufferingPolicy.effectiveVideoQueueEnd(
                rendererQueueEnd: videoQueueEnd,
                decodedBacklogEnd: decodedVideoBacklogEnd
            )
            let reserve = PlaybackBufferingPolicy.commonReserve(
                clock: currentTime,
                videoQueueEnd: effectiveVideoQueueEnd,
                audioQueueEnd: audioQueueEnd,
                hasVideo: hasVideo,
                hasAudio: hasAudio
            ) ?? 0
            NSLog(
                "BUNNY_BUFFER_STATE state=%@ reserve=%.3f desired_rate=%.2f",
                decision.isRebuffering ? "buffering" : "playing",
                reserve,
                desiredRate
            )
        }
    }

    private func completeSeekTransitionIfReady(
        _ transition: inout BunnyNativeSeekTransition?
    ) -> Bool {
        guard let completed = transition, completed.isReady else { return false }
        transition = nil
        NSLog(
            "BUNNY_SEEK_TRANSITION target=%.3f hidden_video=%d discarded_audio=%d discarded_pre_keyframe=%d",
            completed.targetTime,
            completed.hiddenVideoFrames,
            completed.discardedAudioPackets,
            completed.discardedVideoPacketsBeforeRandomAccessPoint
        )
        publishSeekCompletion(
            intent: completed.intent,
            target: completed.targetTime,
            succeeded: true
        )
        return true
    }

    @MainActor
    private func scheduleRecoverySeek(
        to time: TimeInterval,
        reason: BunnyNativeRecoverySeekReason,
        recoveryRequestID: UInt64? = nil,
        replacingUserRequestID: UInt64? = nil
    ) -> Bool {
        stateLock.withLock {
            guard started, !stopped, let activeReader else { return false }
            // Automatic audio maintenance is coalesced into an acknowledged
            // rollback already rebuilding both renderers. A second rollback
            // must likewise wait for the first terminal callback.
            guard activeAcknowledgedRecovery == nil else { return false }
            if let replacingUserRequestID {
                guard activeUserSeekRequestID == replacingUserRequestID else { return false }
                activeUserSeekRequestID = nil
            } else {
                // Audio lifecycle work is lower priority than an explicit
                // scrub. That user request already flushes and reprimes both
                // renderers, so coalescing is both safer and cheaper.
                guard activeUserSeekRequestID == nil else { return false }
            }
            let request = BunnyNativeSeekRequest(
                intent: .recovery(
                    requestID: recoveryRequestID,
                    reason: reason
                ),
                targetTime: max(time.isFinite ? time : 0, 0)
            )
            terminalPlaybackDuration = nil
            let subtitleGeneration = invalidateSubtitleDeliveries()
            pendingSeek = BunnyGenerationOwnedSeekRequest(
                request: request,
                subtitleDeliveryGeneration: subtitleGeneration
            )
            if recoveryRequestID != nil {
                activeAcknowledgedRecovery = request
            }
            activeReader.interruptForSeek()
            return true
        }
    }

    private func scheduleRecoverySeekFromWorker(
        to time: TimeInterval,
        reason: BunnyNativeRecoverySeekReason
    ) -> Bool {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                scheduleRecoverySeek(to: time, reason: reason)
            }
        }
    }

    private func publishSeekCompletion(
        intent: BunnyNativeSeekIntent,
        target: TimeInterval,
        succeeded: Bool
    ) {
        if let requestID = intent.userRequestID {
            clearActiveUserSeekIfMatching(requestID)
            publish { [weak self] in
                self?.onSeekCompleted?(requestID, target, succeeded)
            }
        } else if let reason = intent.recoveryReason {
            if let requestID = intent.recoveryRequestID,
               !claimAcknowledgedRecoveryCompletion(requestID) {
                return
            }
            publish { [weak self] in
                self?.onRecoverySeekCompleted?(
                    intent.recoveryRequestID,
                    reason,
                    target,
                    succeeded
                )
            }
        }
    }

    private func clearActiveUserSeekIfMatching(_ requestID: UInt64) {
        stateLock.withLock {
            if activeUserSeekRequestID == requestID {
                activeUserSeekRequestID = nil
            }
        }
    }

    private func claimAcknowledgedRecoveryCompletion(_ requestID: UInt64) -> Bool {
        stateLock.withLock {
            guard activeAcknowledgedRecovery?.intent.recoveryRequestID == requestID else {
                return false
            }
            activeAcknowledgedRecovery = nil
            return true
        }
    }

    private static func setBooleanSampleAttachment(
        _ sample: CMSampleBuffer,
        key: CFString
    ) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private static func setDataSampleAttachment(
        _ sample: CMSampleBuffer,
        key: CFString,
        data: Data
    ) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        let value = data as CFData
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }

    private func publishPgsPacket(
        _ packet: BunnyNativePacket,
        decoder: OpaquePointer,
        subtitleDeliveryGeneration: UInt64,
        shouldPublish: Bool
    ) throws {
        var error = [CChar](repeating: 0, count: 512)
        let result = packet.data.withUnsafeBytes { bytes in
            error.withUnsafeMutableBufferPointer { errorBuffer in
                stremio_pgs_push_matroska_packet(
                    decoder,
                    packet.presentationTime.value,
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    bytes.count,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }
        guard result >= 0 else {
            throw BunnyNativeDecoderError.core(Self.errorText(error))
        }
        guard result == 1 else { return }
        // Invisible bitmap packets still advance the stateful PGS decoder, but
        // this completed composition must not replace the visible overlay.
        guard shouldPublish else { return }

        let presentation = stremio_pgs_presentation(decoder)
        let start = TimeInterval(presentation.presentation_time_ns) / 1_000_000_000
        if presentation.is_clear != 0 {
            _ = enqueueSubtitleDelivery(
                .bitmap(nil, start: start, duration: nil),
                estimatedBytes: 0,
                generation: subtitleDeliveryGeneration,
                priority: true
            )
            return
        }

        guard let reservation = reserveSubtitleDelivery(
            estimatedBytes: Self.maximumPgsPresentationBytes,
            generation: subtitleDeliveryGeneration
        ) else {
            NSLog(
                "BUNNY_SUBTITLE_DROP codec=PGS pts=%.3f parts=%u error=callback_bound",
                start,
                presentation.part_count
            )
            return
        }
        var committedReservation = false
        defer {
            if !committedReservation {
                cancelSubtitleDeliveryReservation(reservation)
            }
        }

        var parts: [BunnyNativeBitmapSubtitlePart] = []
        parts.reserveCapacity(Int(presentation.part_count))
        for index in 0..<presentation.part_count {
            var raw = StremioPgsPartInfo()
            guard stremio_pgs_part(decoder, index, &raw) == 1,
                  let rgba = raw.rgba,
                  raw.width > 0,
                  raw.height > 0,
                  raw.width <= 16_384,
                  raw.height <= 16_384
            else {
                throw BunnyNativeDecoderError.core("invalid PGS bitmap part")
            }
            let pixelCountResult = UInt64(raw.width)
                .multipliedReportingOverflow(by: UInt64(raw.height))
            guard !pixelCountResult.overflow,
                  pixelCountResult.partialValue <= 8 * 1024 * 1024,
                  let rgbaByteCount = Int(exactly: pixelCountResult.partialValue * 4),
                  rgbaByteCount == raw.rgba_size
            else {
                throw BunnyNativeDecoderError.core("PGS bitmap exceeds the mobile safety limit")
            }
            let pixels = Data(bytes: rgba, count: raw.rgba_size)
            guard let image = Self.rgbaImage(
                pixels,
                width: Int(raw.width),
                height: Int(raw.height)
            ) else {
                throw BunnyNativeDecoderError.core("could not create a PGS image")
            }
            parts.append(
                BunnyNativeBitmapSubtitlePart(
                    image: image,
                    sourceRect: CGRect(
                        x: Int(raw.x),
                        y: Int(raw.y),
                        width: Int(raw.width),
                        height: Int(raw.height)
                    )
                )
            )
        }
        let cue = BunnyNativeBitmapSubtitleCue(
            parts: parts,
            sourceSize: CGSize(
                width: Int(presentation.canvas_width),
                height: Int(presentation.canvas_height)
            )
        )
        // PGS presentations are stateful. Keep the current composition until
        // the decoder publishes an explicit replacement or clear presentation.
        commitSubtitleDelivery(
            .bitmap(cue, start: start, duration: nil),
            reservation: reservation
        )
        committedReservation = true
    }

    private func makeSampleBuffer(
        packet: BunnyNativePacket,
        descriptor: BunnyNativeTrackDescriptor,
        videoDecodeLead: TimeInterval
    ) throws -> CMSampleBuffer {
        guard let format = try packetFormatDescription(
            packet: packet,
            descriptor: descriptor
        ) else {
            throw BunnyNativeDecoderError.unsupportedCodec(descriptor.codecID)
        }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw BunnyNativeDecoderError.sampleBuffer(status)
        }
        status = packet.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.data.count
            )
        }
        guard status == noErr else { throw BunnyNativeDecoderError.sampleBuffer(status) }
        let isCompressedVideo = descriptor.raw.kind
            == UInt32(STREMIO_MEDIA_TRACK_VIDEO)
        let sampleDecodeTime: CMTime
        if isCompressedVideo, packet.decodeTime.isValid {
            sampleDecodeTime = packet.decodeTime - CMTime(
                seconds: max(videoDecodeLead, 0),
                preferredTimescale: 1_000_000_000
            )
        } else {
            sampleDecodeTime = packet.decodeTime
        }
        var timing = CMSampleTimingInfo(
            duration: packet.duration.isValid && packet.duration > .zero ? packet.duration : .invalid,
            presentationTimeStamp: packet.presentationTime,
            // Matroska packets arrive in decode order, but the container does
            // not carry an authoritative DTS. Give VideoToolbox a conservative
            // lead over PTS so deeply reordered B-frames are decoded before
            // their presentation deadlines instead of being marked late.
            decodeTimeStamp: sampleDecodeTime
        )
        var sampleSize = packet.data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw BunnyNativeDecoderError.sampleBuffer(status)
        }
        if descriptor.raw.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO),
           packet.discardPadding.isValid,
           packet.discardPadding != .zero {
            let key = packet.discardPadding > .zero
                ? kCMSampleBufferAttachmentKey_TrimDurationAtEnd
                : kCMSampleBufferAttachmentKey_TrimDurationAtStart
            let requested = CMTimeAbsoluteValue(packet.discardPadding)
            let bounded = packet.duration.isValid && packet.duration > .zero
                ? min(requested, packet.duration)
                : requested
            if bounded > .zero {
                CMSetAttachment(
                    sample,
                    key: key,
                    value: CMTimeCopyAsDictionary(
                        bounded,
                        allocator: kCFAllocatorDefault
                    ),
                    attachmentMode: kCMAttachmentMode_ShouldPropagate
                )
            }
        }
        if #available(iOS 16.0, *),
           let hdr10PlusData = packet.hdr10PlusData,
           hdr10PlusData.first == 0xb5 {
            Self.setDataSampleAttachment(
                sample,
                key: kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                data: hdr10PlusData
            )
            if !reportedHDR10PlusInput {
                reportedHDR10PlusInput = true
                NSLog(
                    "BUNNY_HDR10_PLUS_INPUT bytes=%d",
                    hdr10PlusData.count
                )
            }
        }
        return sample
    }

    private func packetFormatDescription(
        packet: BunnyNativePacket,
        descriptor: BunnyNativeTrackDescriptor
    ) throws -> CMFormatDescription? {
        guard descriptor.raw.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO),
              descriptor.raw.codec == UInt32(STREMIO_MEDIA_CODEC_AC3)
                || descriptor.raw.codec == UInt32(STREMIO_MEDIA_CODEC_EAC3)
        else { return descriptor.formatDescription }
        if let cached = dolbyFormatDescriptions[packet.trackIndex] {
            return cached
        }
        let configuration = packet.data.withUnsafeBytes { bytes in
            stremio_media_dolby_channel_configuration(
                descriptor.raw.codec,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard configuration & UInt32(STREMIO_DOLBY_CHANNEL_CONFIGURATION_VALID) != 0 else {
            return descriptor.formatDescription
        }
        let layout = dolbyAudioChannelLayout(
            configuration: configuration,
            declaredChannelCount: descriptor.raw.channels
        )
        guard let format = try makeFormatDescription(
            raw: descriptor.raw,
            codecPrivate: descriptor.codecPrivate,
            audioChannelLayoutOverride: layout
        ) else { return descriptor.formatDescription }
        dolbyFormatDescriptions[packet.trackIndex] = format
        let audioCodingMode = configuration & 0x7
        let hasLFE = configuration & UInt32(STREMIO_DOLBY_CHANNEL_CONFIGURATION_LFE) != 0
        NSLog(
            "BUNNY_AUDIO_LAYOUT codec=%@ acmod=%u lfe=%@ channels=%u tag=%u",
            descriptor.codecID,
            audioCodingMode,
            hasLFE ? "yes" : "no",
            descriptor.raw.channels,
            layout.mChannelLayoutTag
        )
        return format
    }

    private func scheduleFirstFrameCheck(
        attempt: Int = 0,
        generation requestedGeneration: Int? = nil
    ) {
        let generation = stateLock.withLock { () -> Int? in
            guard !firstFrameDelivered else { return nil }
            if let requestedGeneration {
                guard requestedGeneration == firstFrameCheckGeneration else { return nil }
                return requestedGeneration
            }
            guard !firstFrameCheckScheduled else { return nil }
            firstFrameCheckScheduled = true
            return firstFrameCheckGeneration
        }
        guard let generation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self else { return }
            let current = self.stateLock.withLock {
                !self.firstFrameDelivered
                    && self.firstFrameCheckGeneration == generation
            }
            guard current else { return }
            let isReadyForDisplay: Bool
            if #available(iOS 17.4, *) {
                isReadyForDisplay = self.videoLayer.isReadyForDisplay
            } else {
                isReadyForDisplay = self.videoLayer.status == .rendering
            }
            // On the iOS 17 sample-buffer-renderer surface (notably in the
            // Simulator), `isReadyForDisplay` can remain false even while the
            // synchronizer is advancing and the renderer is consuming queued
            // frames. This check is only scheduled after a presentation frame
            // has been enqueued, so a live clock is equivalent evidence that
            // startup presentation has begun and avoids leaving the player in
            // its opening state indefinitely.
            let presentationHasStarted = self.synchronizer.rate > 0
                && self.currentTime > 0
            if isReadyForDisplay || presentationHasStarted {
                self.deliverFirstFrameOnce()
            } else if attempt < 80, self.videoRendererStatus != .failed {
                self.scheduleFirstFrameCheck(
                    attempt: attempt + 1,
                    generation: generation
                )
            } else if self.videoRendererStatus == .failed {
                self.stateLock.withLock {
                    if self.firstFrameCheckGeneration == generation {
                        self.firstFrameCheckScheduled = false
                    }
                }
                self.onFailure?(
                    self.videoRendererError
                        ?? BunnyNativeDecoderError.formatDescription("video")
                )
            }
        }
    }

    private func deliverFirstFrameOnce() {
        let shouldDeliver = stateLock.withLock { () -> Bool in
            guard !firstFrameDelivered else { return false }
            firstFrameDelivered = true
            firstFrameCheckScheduled = false
            return true
        }
        guard shouldDeliver else { return }
        publish { [weak self] in self?.onFirstFrame?() }
    }

    private var isStopped: Bool {
        stateLock.withLock { stopped }
    }

    private func takePendingSeek() -> BunnyGenerationOwnedSeekRequest? {
        stateLock.withLock {
            defer { pendingSeek = nil }
            return pendingSeek
        }
    }

    private var hasPendingSeek: Bool {
        stateLock.withLock { pendingSeek != nil }
    }

    private var hasPendingTrackSelection: Bool {
        stateLock.withLock {
            pendingAudioSelection != nil || pendingSubtitleSelection != nil
        }
    }

    private func storeMetricsSnapshot(
        decodedVideoFrames: Int,
        droppedVideoFrames: Int,
        renderedAudioFrames: Int,
        videoQueueEnd: TimeInterval,
        audioQueueEnd: TimeInterval
    ) {
        let snapshot = BunnyNativeMetricsSnapshot(
            decodedVideoFrames: decodedVideoFrames,
            droppedVideoFrames: droppedVideoFrames,
            renderedAudioFrames: renderedAudioFrames,
            videoQueueEnd: videoQueueEnd,
            audioQueueEnd: audioQueueEnd
        )
        stateLock.withLock { storedMetricsSnapshot = snapshot }
    }

    private func storeVideoPresentationSnapshot(
        _ presentation: BunnyVideoPresentationSnapshot,
        deliverableBacklogEnd: TimeInterval?
    ) {
        stateLock.withLock {
            let previous = storedMetricsSnapshot
            storedMetricsSnapshot = BunnyNativeMetricsSnapshot(
                decodedVideoFrames: presentation.totalFrames,
                droppedVideoFrames: previous.droppedVideoFrames,
                renderedAudioFrames: previous.renderedAudioFrames,
                videoQueueEnd: presentation.queueEnd,
                audioQueueEnd: previous.audioQueueEnd
            )
            decodedVideoBacklogEnd = deliverableBacklogEnd ?? -.infinity
        }
    }

    private func storeSourcePresentationDiagnostics(
        _ cadence: PlaybackTimestampCadenceSnapshot,
        decodeCadence: PlaybackTimestampCadenceSnapshot,
        clockRatio: Double?
    ) {
        stateLock.withLock {
            storedPresentationDiagnostics.sourcePTSP95Milliseconds =
                cadence.p95ForwardIntervalMilliseconds
            storedPresentationDiagnostics.sourcePTSMaximumMilliseconds =
                cadence.maximumForwardIntervalMilliseconds
            storedPresentationDiagnostics.sourcePTSBackwardTransitions =
                cadence.backwardTransitions
            storedPresentationDiagnostics.sourcePTSDuplicateTransitions =
                cadence.duplicateTransitions
            storedPresentationDiagnostics.sourcePTSOutlierTransitions =
                cadence.irregularForwardTransitions
            storedPresentationDiagnostics.sourceDTSP95Milliseconds =
                decodeCadence.p95ForwardIntervalMilliseconds
            storedPresentationDiagnostics.sourceDTSBackwardTransitions =
                decodeCadence.backwardTransitions
            storedPresentationDiagnostics.playbackClockRatio = clockRatio
        }
    }

    private func requestVideoPerformanceMetrics() {
        guard diagnosticsEnabled else { return }
        guard #available(iOS 17.4, *) else { return }
        let generation = stateLock.withLock { () -> Int? in
            guard !rendererMetricsRequestInFlight, !stopped else { return nil }
            rendererMetricsRequestInFlight = true
            return rendererMetricsGeneration
        }
        guard let generation else { return }
        videoLayer.sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
            self?.consumeVideoPerformanceMetrics(metrics, generation: generation)
        }
    }

    @available(iOS 17.4, *)
    private func consumeVideoPerformanceMetrics(
        _ metrics: AVVideoPerformanceMetrics?,
        generation: Int
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let current = metrics.map {
            PlaybackRendererCumulativeMetrics(
                totalFrames: $0.totalNumberOfFrames,
                droppedFrames: $0.numberOfDroppedFrames,
                corruptedFrames: $0.numberOfCorruptedFrames,
                accumulatedFrameDelay: $0.totalAccumulatedFrameDelay
            )
        }
        let interval = stateLock.withLock { () -> PlaybackRendererCadenceSnapshot? in
            rendererMetricsRequestInFlight = false
            guard generation == rendererMetricsGeneration,
                  !stopped,
                  let current else { return nil }
            defer {
                previousRendererMetrics = current
                previousRendererMetricsAt = now
            }
            storedPresentationDiagnostics.rendererTotalFrames = current.totalFrames
            storedPresentationDiagnostics.rendererDroppedFrames = current.droppedFrames
            storedPresentationDiagnostics.rendererCorruptedFrames = current.corruptedFrames
            guard let previousRendererMetrics,
                  let previousRendererMetricsAt else { return nil }
            let snapshot = PlaybackRendererCadenceDiagnostics.interval(
                previous: previousRendererMetrics,
                current: current,
                elapsed: now - previousRendererMetricsAt
            )
            storedPresentationDiagnostics.rendererFramesPerSecond =
                snapshot.displayedFramesPerSecond
            storedPresentationDiagnostics.rendererAverageDelayMilliseconds =
                snapshot.averageFrameDelayMilliseconds
            return snapshot
        }
        guard let interval else { return }
        let snapshot = presentationDiagnosticsSnapshot
        NSLog(
            "BUNNY_PRESENTATION renderer_batch_fps=%@ interval_frames=%ld interval_dropped=%ld total_frames=%ld total_dropped=%ld corrupt=%ld avg_delay_ms=%@ pts_p95_ms=%@ pts_max_ms=%@ pts_back=%ld pts_dup=%ld pts_outliers=%ld dts_p95_ms=%@ dts_back=%ld clock_ratio=%@ applied_rate=%.2f display_hz=%@ display_p95_ms=%@ display_missed=%ld counters_reset=%@",
            Self.diagnosticNumber(snapshot.rendererFramesPerSecond),
            interval.intervalFrames,
            interval.intervalDroppedFrames,
            interval.totalFrames,
            interval.totalDroppedFrames,
            interval.totalCorruptedFrames,
            Self.diagnosticNumber(snapshot.rendererAverageDelayMilliseconds),
            Self.diagnosticNumber(snapshot.sourcePTSP95Milliseconds),
            Self.diagnosticNumber(snapshot.sourcePTSMaximumMilliseconds),
            snapshot.sourcePTSBackwardTransitions,
            snapshot.sourcePTSDuplicateTransitions,
            snapshot.sourcePTSOutlierTransitions,
            Self.diagnosticNumber(snapshot.sourceDTSP95Milliseconds),
            snapshot.sourceDTSBackwardTransitions,
            Self.diagnosticNumber(snapshot.playbackClockRatio),
            snapshot.appliedRate,
            Self.diagnosticNumber(snapshot.displayRefreshHz),
            Self.diagnosticNumber(snapshot.displayP95IntervalMilliseconds),
            snapshot.displayMissedRefreshes,
            interval.countersReset ? "yes" : "no"
        )
    }

    private static func diagnosticNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        return String(format: "%.3f", value)
    }

    private func reserveSubtitleDelivery(
        estimatedBytes: Int,
        generation: UInt64,
        priority: Bool = false
    ) -> BunnyNativeSubtitleDeliveryReservation? {
        let estimatedBytes = max(estimatedBytes, 0)
        return subtitleDeliveryLock.withLock {
            guard acceptsSubtitleDeliveries,
                  PlaybackSubtitleDeliveryPolicy.accepts(
                    deliveryGeneration: generation,
                    currentGeneration: subtitleDeliveryGeneration
                  ),
                  estimatedBytes <= Self.maximumPendingSubtitleDeliveryBytes
            else { return nil }

            let fits: () -> Bool = {
                let ownedCount = self.pendingSubtitleDeliveries.count
                    + self.reservedSubtitleDeliveryCount
                    + self.inFlightSubtitleDeliveryCount
                let ownedBytes = self.pendingSubtitleDeliveryBytes
                    + self.reservedSubtitleDeliveryBytes
                    + self.inFlightSubtitleDeliveryBytes
                return ownedCount < Self.maximumPendingSubtitleDeliveries
                    && ownedBytes <= Self.maximumPendingSubtitleDeliveryBytes
                        - estimatedBytes
            }
            if !fits(), priority {
                pendingSubtitleDeliveries.removeAll(keepingCapacity: true)
                pendingSubtitleDeliveryBytes = 0
            }
            guard fits() else { return nil }
            reservedSubtitleDeliveryCount += 1
            reservedSubtitleDeliveryBytes += estimatedBytes
            return BunnyNativeSubtitleDeliveryReservation(
                generation: generation,
                estimatedBytes: estimatedBytes
            )
        }
    }

    private func cancelSubtitleDeliveryReservation(
        _ reservation: BunnyNativeSubtitleDeliveryReservation
    ) {
        subtitleDeliveryLock.withLock {
            guard reservation.generation == subtitleDeliveryGeneration else { return }
            reservedSubtitleDeliveryCount = max(reservedSubtitleDeliveryCount - 1, 0)
            reservedSubtitleDeliveryBytes = max(
                reservedSubtitleDeliveryBytes - reservation.estimatedBytes,
                0
            )
        }
    }

    private func commitSubtitleDelivery(
        _ delivery: BunnyNativeSubtitleDelivery,
        reservation: BunnyNativeSubtitleDeliveryReservation
    ) {
        let shouldSchedule = subtitleDeliveryLock.withLock { () -> Bool in
            guard acceptsSubtitleDeliveries,
                  reservation.generation == subtitleDeliveryGeneration
            else { return false }
            reservedSubtitleDeliveryCount = max(reservedSubtitleDeliveryCount - 1, 0)
            reservedSubtitleDeliveryBytes = max(
                reservedSubtitleDeliveryBytes - reservation.estimatedBytes,
                0
            )
            pendingSubtitleDeliveries.append(
                BunnyNativeSubtitleDeliveryEntry(
                    generation: reservation.generation,
                    estimatedBytes: reservation.estimatedBytes,
                    delivery: delivery
                )
            )
            pendingSubtitleDeliveryBytes += reservation.estimatedBytes
            guard !subtitleDeliveryDrainScheduled else { return false }
            subtitleDeliveryDrainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        let generation = reservation.generation
        Task { @MainActor [weak self] in
            self?.drainSubtitleDeliveries(generation: generation)
        }
    }

    @discardableResult
    private func enqueueSubtitleDelivery(
        _ delivery: BunnyNativeSubtitleDelivery,
        estimatedBytes: Int,
        generation: UInt64,
        priority: Bool = false
    ) -> Bool {
        guard let reservation = reserveSubtitleDelivery(
            estimatedBytes: estimatedBytes,
            generation: generation,
            priority: priority
        ) else { return false }
        commitSubtitleDelivery(delivery, reservation: reservation)
        return true
    }

    @MainActor
    private func drainSubtitleDeliveries(generation: UInt64) {
        var deliveredCount = 0
        while deliveredCount
                < PlaybackSubtitleDeliveryPolicy.maximumDeliveriesPerMainActorTurn,
              let entry = takeSubtitleDelivery(generation: generation) {
            switch entry.delivery {
            case let .text(text, start, duration):
                onSubtitle?(text, start, duration)
            case let .bitmap(cue, start, duration):
                onBitmapSubtitle?(cue, start, duration)
            case let .clearAll(start):
                onSubtitle?(nil, start, 0)
                onBitmapSubtitle?(nil, start, nil)
            }
            completeSubtitleDelivery(entry)
            deliveredCount += 1
        }
        guard subtitleDeliveryNeedsAnotherDrain(generation: generation) else {
            return
        }
        Task { @MainActor [weak self] in
            await Task<Never, Never>.yield()
            self?.drainSubtitleDeliveries(generation: generation)
        }
    }

    private func subtitleDeliveryNeedsAnotherDrain(generation: UInt64) -> Bool {
        subtitleDeliveryLock.withLock {
            guard PlaybackSubtitleDeliveryPolicy.accepts(
                deliveryGeneration: generation,
                currentGeneration: subtitleDeliveryGeneration
            ) else { return false }
            guard !pendingSubtitleDeliveries.isEmpty else {
                subtitleDeliveryDrainScheduled = false
                return false
            }
            // Keep the generation's single-owner bit asserted while the next
            // finite MainActor batch is scheduled.
            return true
        }
    }

    private func takeSubtitleDelivery(
        generation: UInt64
    ) -> BunnyNativeSubtitleDeliveryEntry? {
        subtitleDeliveryLock.withLock {
            guard PlaybackSubtitleDeliveryPolicy.accepts(
                deliveryGeneration: generation,
                currentGeneration: subtitleDeliveryGeneration
            ) else { return nil }
            guard !pendingSubtitleDeliveries.isEmpty else {
                subtitleDeliveryDrainScheduled = false
                return nil
            }
            let entry = pendingSubtitleDeliveries.removeFirst()
            pendingSubtitleDeliveryBytes = max(
                pendingSubtitleDeliveryBytes - entry.estimatedBytes,
                0
            )
            inFlightSubtitleDeliveryCount += 1
            inFlightSubtitleDeliveryBytes += entry.estimatedBytes
            return entry
        }
    }

    private func completeSubtitleDelivery(_ entry: BunnyNativeSubtitleDeliveryEntry) {
        subtitleDeliveryLock.withLock {
            guard entry.generation == subtitleDeliveryGeneration else { return }
            inFlightSubtitleDeliveryCount = max(inFlightSubtitleDeliveryCount - 1, 0)
            inFlightSubtitleDeliveryBytes = max(
                inFlightSubtitleDeliveryBytes - entry.estimatedBytes,
                0
            )
        }
    }

    private func currentSubtitleDeliveryGeneration() -> UInt64 {
        subtitleDeliveryLock.withLock { subtitleDeliveryGeneration }
    }

    @MainActor
    @discardableResult
    private func invalidateSubtitleDeliveries(
        acceptingNewDeliveries: Bool = true
    ) -> UInt64 {
        subtitleDeliveryLock.withLock {
            subtitleDeliveryGeneration &+= 1
            pendingSubtitleDeliveries.removeAll(keepingCapacity: true)
            pendingSubtitleDeliveryBytes = 0
            inFlightSubtitleDeliveryCount = 0
            inFlightSubtitleDeliveryBytes = 0
            reservedSubtitleDeliveryCount = 0
            reservedSubtitleDeliveryBytes = 0
            subtitleDeliveryDrainScheduled = false
            acceptsSubtitleDeliveries = acceptingNewDeliveries
            return subtitleDeliveryGeneration
        }
    }

    private func publish(_ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in action() }
    }

    private static func packetTrackKind(_ rawKind: UInt32) -> PlaybackPacketTrackKind {
        switch rawKind {
        case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
            return .video
        case UInt32(STREMIO_MEDIA_TRACK_AUDIO):
            return .audio
        case UInt32(STREMIO_MEDIA_TRACK_SUBTITLE):
            return .subtitle
        default:
            return .other
        }
    }

    private static func hdrInputDiagnostics(
        _ descriptor: BunnyNativeTrackDescriptor
    ) -> BunnyHDRDiagnosticsSnapshot {
        let color = descriptor.videoColor
        let has: (Int) -> Bool = { flag in
            color.flags & UInt32(flag) != 0
        }
        let dolbyVisionConfiguration = ["dvcC", "dvvC", "dvwC"]
            .first { descriptor.additionalCodecAtoms[$0] != nil }
        return BunnyHDRDiagnosticsSnapshot(
            inputBitsPerChannel: has(
                STREMIO_MEDIA_VIDEO_COLOR_BITS_PER_CHANNEL_PRESENT
            ) ? color.bits_per_channel : nil,
            inputPrimaries: has(
                STREMIO_MEDIA_VIDEO_COLOR_PRIMARIES_PRESENT
            ) ? color.primaries : nil,
            inputTransferCharacteristics: has(
                STREMIO_MEDIA_VIDEO_COLOR_TRANSFER_PRESENT
            ) ? color.transfer_characteristics : nil,
            inputMatrixCoefficients: has(
                STREMIO_MEDIA_VIDEO_COLOR_MATRIX_PRESENT
            ) ? color.matrix_coefficients : nil,
            inputRange: has(
                STREMIO_MEDIA_VIDEO_COLOR_RANGE_PRESENT
            ) ? color.range : nil,
            inputHasMasteringMetadata: has(
                STREMIO_MEDIA_VIDEO_COLOR_MASTERING_PRESENT
            ),
            inputHasContentLightLevel: has(
                STREMIO_MEDIA_VIDEO_COLOR_MAX_CLL_PRESENT
            ) || has(STREMIO_MEDIA_VIDEO_COLOR_MAX_FALL_PRESENT),
            inputDolbyVisionConfiguration: dolbyVisionConfiguration
        )
    }

    private static func presentationTrack(_ descriptor: BunnyNativeTrackDescriptor) -> BunnyNativeTrack {
        let kind: BunnyNativeTrackKind = descriptor.raw.kind
            == UInt32(STREMIO_MEDIA_TRACK_AUDIO)
            ? .audio
            : .subtitle
        let fallback = kind == .audio ? "Audio" : "Subtitles"
        return BunnyNativeTrack(
            streamIndex: Int(descriptor.raw.index),
            kind: kind,
            title: descriptor.name.isEmpty ? "\(fallback) \(descriptor.raw.index + 1)" : descriptor.name,
            language: descriptor.language.isEmpty || descriptor.language == "und"
                ? nil
                : descriptor.language,
            codecName: descriptor.codecID,
            sampleRate: kind == .audio ? descriptor.raw.sample_rate : 0,
            channelCount: kind == .audio ? Int(descriptor.raw.channels) : 0
        )
    }

    private static func defaultTrack(
        in descriptors: [BunnyNativeTrackDescriptor]
    ) -> BunnyNativeTrackDescriptor? {
        descriptors.first { $0.raw.flags & UInt32(STREMIO_MEDIA_TRACK_DEFAULT) != 0 }
            ?? descriptors.first
    }

    private static func isEnabled(_ descriptor: BunnyNativeTrackDescriptor) -> Bool {
        descriptor.raw.flags & UInt32(STREMIO_MEDIA_TRACK_ENABLED) != 0
    }

    private static func isApplePlayable(_ descriptor: BunnyNativeTrackDescriptor) -> Bool {
        isEnabled(descriptor)
            && descriptor.raw.flags & UInt32(STREMIO_MEDIA_TRACK_APPLE_DECODABLE) != 0
            && descriptor.formatDescription != nil
    }

    private static func isSelectableSubtitle(
        _ descriptor: BunnyNativeTrackDescriptor
    ) -> Bool {
        descriptor.raw.kind == UInt32(STREMIO_MEDIA_TRACK_SUBTITLE)
            && isEnabled(descriptor)
            && descriptor.raw.flags & UInt32(STREMIO_MEDIA_TRACK_APPLE_DECODABLE) != 0
    }

    private static func presentationSize(
        _ descriptor: BunnyNativeTrackDescriptor
    ) -> CGSize {
        let raw = descriptor.raw
        let usesDisplayAspect = raw.display_unit <= 3
            && raw.display_width > 0
            && raw.display_height > 0
        return CGSize(
            width: Int(usesDisplayAspect ? raw.display_width : raw.width),
            height: Int(usesDisplayAspect ? raw.display_height : raw.height)
        )
    }

    private static func trackText(
        session: OpaquePointer,
        index: UInt32,
        field: Int32
    ) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        _ = buffer.withUnsafeMutableBufferPointer { output in
            stremio_media_track_text(
                session,
                index,
                UInt32(field),
                output.baseAddress,
                output.count
            )
        }
        return decodedCString(buffer)
    }

    private static func errorText(_ buffer: [CChar]) -> String {
        let value = decodedCString(buffer)
        return value.isEmpty ? "unknown media-core error" : value
    }

    private static func decodedCString(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func normalizedSubtitleText(_ data: Data, codec: UInt32) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if codec == UInt32(STREMIO_MEDIA_CODEC_ASS) {
            // Embedded Matroska ASS packets prefix ReadOrder, Layer, Style,
            // Name, margins, and Effect before the dialogue payload.
            text = text.split(
                separator: ",",
                maxSplits: 8,
                omittingEmptySubsequences: false
            ).last.map(String.init) ?? text
            var normalized = ""
            var insideOverride = false
            for character in text {
                if character == "{" {
                    insideOverride = true
                } else if character == "}" {
                    insideOverride = false
                } else if !insideOverride {
                    normalized.append(character)
                }
            }
            text = normalized
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func rgbaImage(_ data: Data, width: Int, height: Int) -> UIImage? {
        guard width > 0,
              height > 0,
              data.count == width * height * 4,
              let provider = CGDataProvider(data: data as CFData)
        else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

private func standardAudioChannelLayout(
    codec: UInt32,
    channelCount: UInt32
) -> AudioChannelLayout {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = switch (codec, channelCount) {
    case (UInt32(STREMIO_MEDIA_CODEC_AAC), 3): kAudioChannelLayoutTag_AAC_3_0
    case (UInt32(STREMIO_MEDIA_CODEC_AAC), 4): kAudioChannelLayoutTag_AAC_4_0
    case (UInt32(STREMIO_MEDIA_CODEC_AAC), 5): kAudioChannelLayoutTag_AAC_5_0
    case (UInt32(STREMIO_MEDIA_CODEC_AAC), 6): kAudioChannelLayoutTag_AAC_5_1
    case (UInt32(STREMIO_MEDIA_CODEC_AAC), 7): kAudioChannelLayoutTag_AAC_6_1
    case (UInt32(STREMIO_MEDIA_CODEC_AAC), 8): kAudioChannelLayoutTag_AAC_7_1_B
    case (UInt32(STREMIO_MEDIA_CODEC_OPUS), 3): kAudioChannelLayoutTag_Ogg_3_0
    case (UInt32(STREMIO_MEDIA_CODEC_OPUS), 4): kAudioChannelLayoutTag_Ogg_4_0
    case (UInt32(STREMIO_MEDIA_CODEC_OPUS), 5): kAudioChannelLayoutTag_Ogg_5_0
    case (UInt32(STREMIO_MEDIA_CODEC_OPUS), 6): kAudioChannelLayoutTag_Ogg_5_1
    case (UInt32(STREMIO_MEDIA_CODEC_OPUS), 7): kAudioChannelLayoutTag_Ogg_6_1
    case (UInt32(STREMIO_MEDIA_CODEC_OPUS), 8): kAudioChannelLayoutTag_Ogg_7_1
    case (UInt32(STREMIO_MEDIA_CODEC_AC3), 3),
         (UInt32(STREMIO_MEDIA_CODEC_EAC3), 3): kAudioChannelLayoutTag_AC3_3_0
    case (UInt32(STREMIO_MEDIA_CODEC_AC3), 4),
         (UInt32(STREMIO_MEDIA_CODEC_EAC3), 4): kAudioChannelLayoutTag_AC3_3_1
    case (UInt32(STREMIO_MEDIA_CODEC_AC3), 5),
         (UInt32(STREMIO_MEDIA_CODEC_EAC3), 5): kAudioChannelLayoutTag_MPEG_5_0_C
    case (UInt32(STREMIO_MEDIA_CODEC_AC3), 6),
         (UInt32(STREMIO_MEDIA_CODEC_EAC3), 6): kAudioChannelLayoutTag_MPEG_5_1_C
    case (UInt32(STREMIO_MEDIA_CODEC_EAC3), 7): kAudioChannelLayoutTag_EAC3_6_1_A
    case (UInt32(STREMIO_MEDIA_CODEC_EAC3), 8): kAudioChannelLayoutTag_EAC3_7_1_A
    case (_, 1): kAudioChannelLayoutTag_Mono
    case (_, 2): kAudioChannelLayoutTag_Stereo
    case (_, 3): kAudioChannelLayoutTag_MPEG_3_0_A
    case (_, 4): kAudioChannelLayoutTag_MPEG_4_0_A
    case (_, 5): kAudioChannelLayoutTag_MPEG_5_0_A
    case (_, 6): kAudioChannelLayoutTag_MPEG_5_1_A
    case (_, 7): kAudioChannelLayoutTag_MPEG_6_1_A
    case (_, 8): kAudioChannelLayoutTag_MPEG_7_1_C
    default: kAudioChannelLayoutTag_DiscreteInOrder | channelCount
    }
    return layout
}

private func dolbyAudioChannelLayout(
    configuration: UInt32,
    declaredChannelCount: UInt32
) -> AudioChannelLayout {
    let audioCodingMode = Int(configuration & 0x7)
    let hasLFE = configuration & UInt32(STREMIO_DOLBY_CHANNEL_CONFIGURATION_LFE) != 0
    let baseChannels = [2, 1, 2, 3, 3, 4, 4, 5]
    guard baseChannels.indices.contains(audioCodingMode),
          UInt32(baseChannels[audioCodingMode] + (hasLFE ? 1 : 0)) == declaredChannelCount
    else {
        return standardAudioChannelLayout(
            codec: UInt32(STREMIO_MEDIA_CODEC_EAC3),
            channelCount: declaredChannelCount
        )
    }

    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = switch (audioCodingMode, hasLFE) {
    case (0, false), (2, false): kAudioChannelLayoutTag_Stereo
    case (1, false): kAudioChannelLayoutTag_Mono
    case (1, true): kAudioChannelLayoutTag_AC3_1_0_1
    case (3, false): kAudioChannelLayoutTag_AC3_3_0
    case (3, true): kAudioChannelLayoutTag_AC3_3_0_1
    case (4, true): kAudioChannelLayoutTag_AC3_2_1_1
    case (5, false): kAudioChannelLayoutTag_AC3_3_1
    case (5, true): kAudioChannelLayoutTag_AC3_3_1_1
    case (6, false): kAudioChannelLayoutTag_Quadraphonic
    case (7, false): kAudioChannelLayoutTag_MPEG_5_0_C
    case (7, true): kAudioChannelLayoutTag_MPEG_5_1_C
    default: kAudioChannelLayoutTag_UseChannelBitmap
    }
    if layout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap {
        let baseBitmap: AudioChannelBitmap = switch audioCodingMode {
        case 0, 2: [.bit_Left, .bit_Right]
        case 4: [.bit_Left, .bit_Right, .bit_CenterSurround]
        case 6: [.bit_Left, .bit_Right, .bit_LeftSurround, .bit_RightSurround]
        default: []
        }
        layout.mChannelBitmap = hasLFE
            ? baseBitmap.union(.bit_LFEScreen)
            : baseBitmap
    }
    return layout
}

private func makeFormatDescription(
    raw: StremioMediaTrackInfo,
    codecPrivate: Data,
    videoColor: StremioMediaVideoColorInfo? = nil,
    additionalCodecAtoms: [String: Data] = [:],
    audioChannelLayoutOverride: AudioChannelLayout? = nil
) throws -> CMFormatDescription? {
    switch raw.kind {
    case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
        let codecAndAtom: (CMVideoCodecType, String)? = switch raw.codec {
        case UInt32(STREMIO_MEDIA_CODEC_H264): (kCMVideoCodecType_H264, "avcC")
        case UInt32(STREMIO_MEDIA_CODEC_HEVC): (kCMVideoCodecType_HEVC, "hvcC")
        case UInt32(STREMIO_MEDIA_CODEC_AV1): (kCMVideoCodecType_AV1, "av1C")
        case UInt32(STREMIO_MEDIA_CODEC_VP9): (kCMVideoCodecType_VP9, "vpcC")
        case UInt32(STREMIO_MEDIA_CODEC_MPEG4): (kCMVideoCodecType_MPEG4Video, "esds")
        default: nil
        }
        guard let (baseCodec, atom) = codecAndAtom else { return nil }
        guard raw.width > 0,
              raw.height > 0,
              raw.width <= 16_384,
              raw.height <= 16_384,
              let width = Int32(exactly: raw.width),
              let height = Int32(exactly: raw.height)
        else { return nil }
        var atoms = additionalCodecAtoms.reduce(into: [String: Any]()) {
            $0[$1.key] = $1.value
        }
        if !codecPrivate.isEmpty {
            atoms[atom] = codecPrivate
        }
        var extensions = videoFormatExtensions(videoColor, track: raw)
        if !atoms.isEmpty {
            extensions[
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
            ] = atoms
        }
        let hasDolbyVisionConfiguration = additionalCodecAtoms.keys.contains {
            $0 == "dvcC" || $0 == "dvvC" || $0 == "dvwC"
        }
        let prefersDolbyVision = baseCodec == kCMVideoCodecType_HEVC
            && hasDolbyVisionConfiguration
            && VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
        let codecCandidates: [CMVideoCodecType] = prefersDolbyVision
            ? [kCMVideoCodecType_DolbyVisionHEVC, baseCodec]
            : [baseCodec]
        var descriptions = [CMVideoFormatDescription]()
        for codec in codecCandidates {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codec,
                width: width,
                height: height,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &description
            )
            if status == noErr, let description {
                descriptions.append(description)
            }
        }
        if baseCodec == kCMVideoCodecType_HEVC,
           let normalized = makeHEVCFormatDescriptionFromConfigurationRecord(
                codecPrivate,
                color: videoColor,
                additionalCodecAtoms: additionalCodecAtoms,
                track: raw
           ) {
            descriptions.append(normalized)
        }
        guard !descriptions.isEmpty else { return nil }
        for (index, description) in descriptions.enumerated()
        where videoFormatSupportsDecompression(description) {
            if baseCodec == kCMVideoCodecType_HEVC, index > 0 {
                    NSLog(
                        "BUNNY_HEVC_FORMAT_FALLBACK candidate=%d format=%@",
                        index,
                        bunnyFourCC(
                            CMFormatDescriptionGetMediaSubType(description)
                        )
                    )
            }
            return description
        }
        return nil
    case UInt32(STREMIO_MEDIA_TRACK_AUDIO):
        let formatAndFrames: (AudioFormatID, UInt32)? = switch raw.codec {
        case UInt32(STREMIO_MEDIA_CODEC_AAC):
            (kAudioFormatMPEG4AAC, max(raw.audio_frames_per_packet, 1))
        case UInt32(STREMIO_MEDIA_CODEC_AC3): (kAudioFormatAC3, 1_536)
        // E-AC-3 is variable-frame-rate (256/512/768/1,536 samples). Each
        // CMSampleBuffer carries the exact Rust-parsed duration.
        case UInt32(STREMIO_MEDIA_CODEC_EAC3): (kAudioFormatEnhancedAC3, 0)
        case UInt32(STREMIO_MEDIA_CODEC_FLAC): (kAudioFormatFLAC, 0)
        case UInt32(STREMIO_MEDIA_CODEC_OPUS): (kAudioFormatOpus, 0)
        case UInt32(STREMIO_MEDIA_CODEC_PCM): (kAudioFormatLinearPCM, 1)
        default: nil
        }
        guard let (format, framesPerPacket) = formatAndFrames else { return nil }
        guard raw.sample_rate.isFinite,
              raw.sample_rate > 0,
              raw.sample_rate <= 768_000,
              (1...32).contains(raw.channels)
        else { return nil }
        let isPCM = format == kAudioFormatLinearPCM
        let pcmBits: UInt32
        let pcmBytesPerFrame: UInt32
        if isPCM {
            pcmBits = raw.bit_depth == 0 ? 16 : raw.bit_depth
            guard (8...64).contains(pcmBits),
                  let bytesPerFrame = UInt32(
                    exactly: UInt64(raw.channels) * UInt64((pcmBits + 7) / 8)
                  )
            else { return nil }
            pcmBytesPerFrame = bytesPerFrame
        } else {
            pcmBits = 0
            pcmBytesPerFrame = 0
        }
        var stream = AudioStreamBasicDescription(
            mSampleRate: raw.sample_rate,
            mFormatID: format,
            mFormatFlags: isPCM
                ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                : 0,
            mBytesPerPacket: pcmBytesPerFrame,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: pcmBytesPerFrame,
            mChannelsPerFrame: raw.channels,
            // Compressed ASBDs must leave bit depth at zero. The Matroska
            // BitDepth field describes decoded output and passing it through
            // makes AudioConverter reject valid AAC/AC-3/FLAC packets.
            mBitsPerChannel: pcmBits,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        var channelLayout = audioChannelLayoutOverride ?? standardAudioChannelLayout(
            codec: raw.codec,
            channelCount: raw.channels
        )
        let status = codecPrivate.withUnsafeBytes { bytes in
            withUnsafePointer(to: &channelLayout) { layoutPointer in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &stream,
                    layoutSize: MemoryLayout<AudioChannelLayout>.size,
                    layout: layoutPointer,
                    magicCookieSize: codecPrivate.count,
                    magicCookie: bytes.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr else { return nil }
        return description
    case UInt32(STREMIO_MEDIA_TRACK_SUBTITLE):
        return nil
    default:
        return nil
    }
}

private func makeHEVCFormatDescriptionFromConfigurationRecord(
    _ configuration: Data,
    color: StremioMediaVideoColorInfo?,
    additionalCodecAtoms: [String: Data],
    track: StremioMediaTrackInfo
) -> CMVideoFormatDescription? {
    guard let parsed = parseHEVCParameterSets(configuration) else { return nil }
    return makeHEVCFormatDescription(
        parameterSets: parsed.parameterSets,
        nalUnitHeaderLength: parsed.nalUnitHeaderLength,
        color: color,
        additionalCodecAtoms: additionalCodecAtoms,
        track: track
    )
}

private func makeHEVCFormatDescription(
    parameterSets: [Data],
    nalUnitHeaderLength: Int32,
    color: StremioMediaVideoColorInfo?,
    additionalCodecAtoms: [String: Data],
    track: StremioMediaTrackInfo
) -> CMVideoFormatDescription? {
    guard !parameterSets.isEmpty, (1...4).contains(nalUnitHeaderLength) else {
        return nil
    }
    let allocated = parameterSets.map { data -> UnsafeMutablePointer<UInt8> in
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: pointer, count: data.count)
        return pointer
    }
    defer { allocated.forEach { $0.deallocate() } }
    let pointers = allocated.map { UnsafePointer($0) }
    let sizes = parameterSets.map(\.count)
    var extensions = videoFormatExtensions(color, track: track)
    if !additionalCodecAtoms.isEmpty {
        extensions[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
        ] = additionalCodecAtoms
    }
    var description: CMVideoFormatDescription?
    let status = pointers.withUnsafeBufferPointer { pointerBuffer in
        sizes.withUnsafeBufferPointer { sizeBuffer in
            guard let pointerBase = pointerBuffer.baseAddress,
                  let sizeBase = sizeBuffer.baseAddress else {
                return kCMFormatDescriptionError_InvalidParameter
            }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointerBuffer.count,
                parameterSetPointers: pointerBase,
                parameterSetSizes: sizeBase,
                nalUnitHeaderLength: nalUnitHeaderLength,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &description
            )
        }
    }
    return status == noErr ? description : nil
}

private func parseHEVCParameterSets(
    _ configuration: Data
) -> (parameterSets: [Data], nalUnitHeaderLength: Int32)? {
    if configuration.count >= 23, configuration[0] == 1 {
        let nalUnitHeaderLength = Int32((configuration[21] & 0x03) + 1)
        let arrayCount = Int(configuration[22])
        var cursor = 23
        var parameterSets = [Data]()
        var foundTypes = Set<UInt8>()
        for _ in 0..<arrayCount {
            guard cursor + 3 <= configuration.count else { return nil }
            let nalType = configuration[cursor] & 0x3f
            cursor += 1
            let count = Int(configuration[cursor]) << 8
                | Int(configuration[cursor + 1])
            cursor += 2
            for _ in 0..<count {
                guard cursor + 2 <= configuration.count else { return nil }
                let size = Int(configuration[cursor]) << 8
                    | Int(configuration[cursor + 1])
                cursor += 2
                guard size > 0, cursor + size <= configuration.count else {
                    return nil
                }
                if nalType == 32 || nalType == 33 || nalType == 34 {
                    parameterSets.append(
                        configuration.subdata(in: cursor..<(cursor + size))
                    )
                    foundTypes.insert(nalType)
                }
                cursor += size
            }
        }
        guard foundTypes.isSuperset(of: [32, 33, 34]) else { return nil }
        return (parameterSets, nalUnitHeaderLength)
    }

    let bytes = [UInt8](configuration)
    var starts = [(offset: Int, prefixLength: Int)]()
    var index = 0
    while index + 3 <= bytes.count {
        if index + 4 <= bytes.count,
           bytes[index] == 0,
           bytes[index + 1] == 0,
           bytes[index + 2] == 0,
           bytes[index + 3] == 1 {
            starts.append((index, 4))
            index += 4
        } else if bytes[index] == 0,
                  bytes[index + 1] == 0,
                  bytes[index + 2] == 1 {
            starts.append((index, 3))
            index += 3
        } else {
            index += 1
        }
    }
    guard !starts.isEmpty else { return nil }
    var parameterSets = [Data]()
    var foundTypes = Set<UInt8>()
    for (startIndex, start) in starts.enumerated() {
        let payloadStart = start.offset + start.prefixLength
        var payloadEnd = startIndex + 1 < starts.count
            ? starts[startIndex + 1].offset
            : bytes.count
        while payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
            payloadEnd -= 1
        }
        guard payloadStart + 2 <= payloadEnd else { continue }
        let nalType = (bytes[payloadStart] >> 1) & 0x3f
        if nalType == 32 || nalType == 33 || nalType == 34 {
            parameterSets.append(Data(bytes[payloadStart..<payloadEnd]))
            foundTypes.insert(nalType)
        }
    }
    guard foundTypes.isSuperset(of: [32, 33, 34]) else { return nil }
    return (parameterSets, 4)
}

private func hevcParameterSetsInPacket(
    _ packet: Data,
    preferredLengthFieldBytes: Int
) -> (parameterSets: [Data], nalUnitHeaderLength: Int32)? {
    let lengthCandidates = ([preferredLengthFieldBytes, 4, 2, 1])
        .filter { (1...4).contains($0) }
        .reduce(into: [Int]()) { values, value in
            if !values.contains(value) { values.append(value) }
        }
    for lengthFieldBytes in lengthCandidates {
        if let units = lengthPrefixedNALUnits(
            packet,
            lengthFieldBytes: lengthFieldBytes
        ) {
            let parameterSets = units.filter {
                guard let first = $0.first else { return false }
                let type = (first >> 1) & 0x3f
                return type == 32 || type == 33 || type == 34
            }
            if !parameterSets.isEmpty {
                return (parameterSets, Int32(lengthFieldBytes))
            }
        }
    }
    let units = annexBNALUnits(packet)
    let parameterSets = units.filter {
        guard let first = $0.first else { return false }
        let type = (first >> 1) & 0x3f
        return type == 32 || type == 33 || type == 34
    }
    return parameterSets.isEmpty ? nil : (parameterSets, 4)
}

private func lengthPrefixedNALUnits(
    _ packet: Data,
    lengthFieldBytes: Int
) -> [Data]? {
    guard (1...4).contains(lengthFieldBytes),
          packet.count > lengthFieldBytes else { return nil }
    let bytes = [UInt8](packet)
    var units = [Data]()
    var cursor = 0
    while cursor < bytes.count {
        guard cursor + lengthFieldBytes <= bytes.count else { return nil }
        var size = 0
        for byte in bytes[cursor..<(cursor + lengthFieldBytes)] {
            size = (size << 8) | Int(byte)
        }
        cursor += lengthFieldBytes
        guard size >= 2, cursor + size <= bytes.count else { return nil }
        let nalType = (bytes[cursor] >> 1) & 0x3f
        guard nalType <= 63 else { return nil }
        units.append(Data(bytes[cursor..<(cursor + size)]))
        cursor += size
    }
    return cursor == bytes.count && !units.isEmpty ? units : nil
}

private func annexBNALUnits(_ packet: Data) -> [Data] {
    let bytes = [UInt8](packet)
    var starts = [(offset: Int, prefixLength: Int)]()
    var index = 0
    while index + 3 <= bytes.count {
        if index + 4 <= bytes.count,
           bytes[index] == 0,
           bytes[index + 1] == 0,
           bytes[index + 2] == 0,
           bytes[index + 3] == 1 {
            starts.append((index, 4))
            index += 4
        } else if bytes[index] == 0,
                  bytes[index + 1] == 0,
                  bytes[index + 2] == 1 {
            starts.append((index, 3))
            index += 3
        } else {
            index += 1
        }
    }
    var units = [Data]()
    for (startIndex, start) in starts.enumerated() {
        let payloadStart = start.offset + start.prefixLength
        var payloadEnd = startIndex + 1 < starts.count
            ? starts[startIndex + 1].offset
            : bytes.count
        while payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
            payloadEnd -= 1
        }
        if payloadStart + 2 <= payloadEnd {
            units.append(Data(bytes[payloadStart..<payloadEnd]))
        }
    }
    return units
}

private func videoFormatSupportsDecompression(
    _ description: CMVideoFormatDescription
) -> Bool {
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: description,
        decoderSpecification: nil,
        imageBufferAttributes: nil,
        outputCallback: nil,
        decompressionSessionOut: &session
    )
    if let session {
        VTDecompressionSessionInvalidate(session)
    }
    return status == noErr
}

private func videoFormatExtensions(
    _ color: StremioMediaVideoColorInfo?,
    track: StremioMediaTrackInfo? = nil
) -> [String: Any] {
    var extensions = [String: Any]()
    if let track,
       let aspect = videoPixelAspectRatio(track) {
        extensions[kCMFormatDescriptionExtension_PixelAspectRatio as String] = [
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String:
                aspect.horizontal,
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String:
                aspect.vertical,
        ]
    }
    guard let color, color.abi_version == 1 else { return extensions }
    let has: (Int) -> Bool = { flag in
        color.flags & UInt32(flag) != 0
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_PRIMARIES_PRESENT),
       let codePoint = Int32(exactly: color.primaries),
       let value = CVColorPrimariesGetStringForIntegerCodePoint(codePoint)?
        .takeUnretainedValue() {
        extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = value
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_TRANSFER_PRESENT),
       let codePoint = Int32(exactly: color.transfer_characteristics),
       let value = CVTransferFunctionGetStringForIntegerCodePoint(codePoint)?
        .takeUnretainedValue() {
        extensions[kCMFormatDescriptionExtension_TransferFunction as String] = value
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_MATRIX_PRESENT),
       let codePoint = Int32(exactly: color.matrix_coefficients),
       let value = CVYCbCrMatrixGetStringForIntegerCodePoint(codePoint)?
        .takeUnretainedValue() {
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = value
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_RANGE_PRESENT) {
        switch color.range {
        case 1:
            extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = false
        case 2:
            extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = true
        default:
            break
        }
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_BITS_PER_CHANNEL_PRESENT),
       color.bits_per_channel > 0 {
        extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] =
            color.bits_per_channel
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_MASTERING_PRESENT),
       let mastering = masteringDisplayColorVolumeData(color) {
        extensions[
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
        ] = mastering
    }
    if has(STREMIO_MEDIA_VIDEO_COLOR_MAX_CLL_PRESENT)
        || has(STREMIO_MEDIA_VIDEO_COLOR_MAX_FALL_PRESENT) {
        var contentLightLevel = Data()
        appendBigEndian(clampedUInt16(Double(color.max_cll)), to: &contentLightLevel)
        appendBigEndian(clampedUInt16(Double(color.max_fall)), to: &contentLightLevel)
        extensions[
            kCMFormatDescriptionExtension_ContentLightLevelInfo as String
        ] = contentLightLevel
    }
    return extensions
}

private func videoPixelAspectRatio(
    _ track: StremioMediaTrackInfo
) -> (horizontal: UInt32, vertical: UInt32)? {
    guard track.display_unit <= 3,
          track.width > 0,
          track.height > 0,
          track.display_width > 0,
          track.display_height > 0
    else { return nil }
    let horizontal = UInt64(track.display_width) * UInt64(track.height)
    let vertical = UInt64(track.display_height) * UInt64(track.width)
    guard horizontal > 0, vertical > 0, horizontal != vertical else { return nil }
    let divisor = greatestCommonDivisor(horizontal, vertical)
    guard let reducedHorizontal = UInt32(exactly: horizontal / divisor),
          let reducedVertical = UInt32(exactly: vertical / divisor)
    else { return nil }
    return (reducedHorizontal, reducedVertical)
}

private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var lhs = lhs
    var rhs = rhs
    while rhs != 0 {
        (lhs, rhs) = (rhs, lhs % rhs)
    }
    return max(lhs, 1)
}

private func masteringDisplayColorVolumeData(
    _ color: StremioMediaVideoColorInfo
) -> Data? {
    let chromaticities = [
        color.primary_g_x, color.primary_g_y,
        color.primary_b_x, color.primary_b_y,
        color.primary_r_x, color.primary_r_y,
        color.white_point_x, color.white_point_y,
    ]
    guard chromaticities.allSatisfy({ $0.isFinite && $0 >= 0 }),
          color.luminance_max.isFinite,
          color.luminance_max >= 0,
          color.luminance_min.isFinite,
          color.luminance_min >= 0
    else { return nil }
    var data = Data()
    for value in chromaticities {
        appendBigEndian(clampedUInt16(value * 50_000), to: &data)
    }
    appendBigEndian(clampedUInt32(color.luminance_max * 10_000), to: &data)
    appendBigEndian(clampedUInt32(color.luminance_min * 10_000), to: &data)
    return data.count == 24 ? data : nil
}

private func clampedUInt16(_ value: Double) -> UInt16 {
    guard value.isFinite else { return 0 }
    return UInt16(min(max(value.rounded(), 0), Double(UInt16.max)))
}

private func clampedUInt32(_ value: Double) -> UInt32 {
    guard value.isFinite else { return 0 }
    return UInt32(min(max(value.rounded(), 0), Double(UInt32.max)))
}

private func appendBigEndian(_ value: UInt16, to data: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func bunnyFourCC(_ value: OSType) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii)
        ?? String(format: "0x%08x", value)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
