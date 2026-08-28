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
        let expected = samples.1.filter { $0 > 0 }.sorted()
        let median = percentile(sorted, fraction: 0.50)
        let p95 = percentile(sorted, fraction: 0.95)
        let expectedMedian = percentile(expected, fraction: 0.50)
        let missed = zip(samples.0, samples.1).reduce(into: 0) { result, pair in
            guard pair.1 > 0, pair.0 > pair.1 * 1.5 else { return }
            result += max(Int((pair.0 / pair.1).rounded()) - 1, 1)
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

private enum BunnyNativeDecoderError: LocalizedError {
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

private struct BunnyURLOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty
        else { return nil }
        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else if scheme == "https" {
            port = 443
        } else if scheme == "http" {
            port = 80
        } else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = port
    }
}

private struct BunnyRemoteSourcePolicy: Sendable {
    private let sourceOrigin: BunnyURLOrigin
    private let trustedPrivateOrigin: BunnyURLOrigin?

    init(sourceURL: URL, trustedPrivateOrigin: URL?) throws {
        guard let sourceOrigin = BunnyURLOrigin(sourceURL) else {
            throw BunnyNativeDecoderError.invalidSource("only HTTP and HTTPS media URLs are supported")
        }
        let trustedOrigin = trustedPrivateOrigin.flatMap(BunnyURLOrigin.init)
        try Self.validate(sourceURL, trustedPrivateOrigin: trustedOrigin)
        self.sourceOrigin = sourceOrigin
        self.trustedPrivateOrigin = trustedOrigin
    }

    func validateRequestURL(_ url: URL) throws {
        guard url.user == nil, url.password == nil else {
            throw BunnyNativeDecoderError.invalidSource("credentials are not allowed in media URLs")
        }
        guard BunnyURLOrigin(url) != sourceOrigin else { return }
        try Self.validate(url, trustedPrivateOrigin: trustedPrivateOrigin)
    }

    private static func validate(
        _ url: URL,
        trustedPrivateOrigin: BunnyURLOrigin?
    ) throws {
        guard let origin = BunnyURLOrigin(url),
              origin.scheme == "http" || origin.scheme == "https"
        else {
            throw BunnyNativeDecoderError.invalidSource("only HTTP and HTTPS media URLs are supported")
        }
        guard url.user == nil, url.password == nil else {
            throw BunnyNativeDecoderError.invalidSource("credentials are not allowed in media URLs")
        }
        if origin == trustedPrivateOrigin {
            return
        }
        guard !Self.isLocalHostname(origin.host),
              let addresses = Self.resolvedAddresses(for: origin.host),
              !addresses.isEmpty,
              !addresses.contains(where: Self.isRestrictedAddress)
        else {
            throw BunnyNativeDecoderError.invalidSource("private or local network destinations are blocked")
        }
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".home.arpa")
    }

    private static func resolvedAddresses(for host: String) -> [[UInt8]]? {
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &result) == 0 else { return nil }
        defer { if let result { freeaddrinfo(result) } }

        var addresses: [[UInt8]] = []
        var cursor = result
        while let current = cursor {
            let info = current.pointee
            if info.ai_family == AF_INET, let address = info.ai_addr {
                let ipv4 = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee
                    .sin_addr
                withUnsafeBytes(of: ipv4) { addresses.append(Array($0)) }
            } else if info.ai_family == AF_INET6, let address = info.ai_addr {
                let ipv6 = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee
                    .sin6_addr
                withUnsafeBytes(of: ipv6) { addresses.append(Array($0)) }
            }
            cursor = info.ai_next
        }
        return addresses
    }

    private static func isRestrictedAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let first = bytes[0]
            let second = bytes[1]
            return first == 0
                || first == 10
                || first == 127
                || (first == 100 && (64...127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
                || (first == 192 && second == 0)
                || (first == 198 && (second == 18 || second == 19))
                || (first == 198 && second == 51 && bytes[2] == 100)
                || (first == 203 && second == 0 && bytes[2] == 113)
                || first >= 224
        }
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        if bytes[0] == 0xff || bytes[0] & 0xfe == 0xfc { return true }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return true }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return true
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isRestrictedAddress(Array(bytes.suffix(4)))
        }
        return false
    }
}

private struct BunnyContentRange {
    let lowerBound: UInt64
    let upperBound: UInt64
    let totalLength: UInt64

    init?(_ value: String?) {
        guard let value else { return nil }
        let pieces = value.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" })
        guard pieces.count == 4,
              pieces[0].lowercased() == "bytes",
              let lower = UInt64(pieces[1]),
              let upper = UInt64(pieces[2]),
              let total = UInt64(pieces[3]),
              lower <= upper,
              upper < total
        else { return nil }
        lowerBound = lower
        upperBound = upper
        totalLength = total
    }
}

private final class BunnyRangeFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        let data: Data
        let response: HTTPURLResponse
    }

    private let policy: BunnyRemoteSourcePolicy
    private let lock = NSLock()
    private let sessionLock = NSLock()
    private var maximumBytes = 1
    private var semaphore = DispatchSemaphore(value: 0)
    private var progressSemaphore = DispatchSemaphore(value: 0)
    private var received = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var finished = false
    private var activeTask: URLSessionDataTask?
    private var activeTaskIdentifier: Int?
    private var activeOperationID: Int?
    private var sessionStorage: URLSession?
    private var sessionInvalidated = false

    init(policy: BunnyRemoteSourcePolicy) {
        self.policy = policy
    }

    func run(
        _ request: URLRequest,
        maximumBytes: Int,
        timeout: TimeInterval = 30,
        startGuard: (() -> Bool)? = nil,
        operationID: Int? = nil
    ) throws -> Result {
        guard let url = request.url else {
            throw BunnyNativeDecoderError.invalidSource("the media request has no URL")
        }
        try policy.validateRequestURL(url)
        let requestSemaphore = DispatchSemaphore(value: 0)
        let requestProgressSemaphore = DispatchSemaphore(value: 0)
        let task = try makeTask(with: request)
        let shouldStart = lock.withLock { () -> Bool in
            self.maximumBytes = max(maximumBytes, 1)
            semaphore = requestSemaphore
            progressSemaphore = requestProgressSemaphore
            received = Data()
            response = nil
            failure = nil
            finished = false
            activeTask = task
            activeTaskIdentifier = task.taskIdentifier
            activeOperationID = operationID
            return startGuard?() ?? true
        }
        guard shouldStart else {
            finish(BunnyNativeDecoderError.stopped, taskIdentifier: task.taskIdentifier)
            throw BunnyNativeDecoderError.stopped
        }
        task.resume()
        guard requestSemaphore.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            finish(
                BunnyNativeDecoderError.network("request timed out"),
                taskIdentifier: task.taskIdentifier
            )
            throw BunnyNativeDecoderError.network("request timed out")
        }
        lock.lock()
        defer { lock.unlock() }
        if activeTaskIdentifier == task.taskIdentifier {
            activeTask = nil
            activeTaskIdentifier = nil
        }
        if let failure { throw failure }
        guard let response else {
            throw BunnyNativeDecoderError.network("missing HTTP response")
        }
        return Result(data: received, response: response)
    }

    /// Copies the prefix of an in-flight range as URLSession delivers it.
    /// Ordered demux reads usually need only a few bytes at a time; making
    /// those bytes wait for an entire 8 MiB response creates artificial
    /// multi-second stalls on high-bitrate sources.
    func copyReceived(
        operationID: Int,
        relativeOffset: Int,
        to output: UnsafeMutablePointer<UInt8>,
        maximumLength: Int
    ) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperationID == operationID,
              relativeOffset >= 0,
              relativeOffset < received.count,
              maximumLength > 0
        else { return nil }
        let count = min(maximumLength, received.count - relativeOffset)
        received.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            output.update(
                from: base.advanced(by: relativeOffset).assumingMemoryBound(to: UInt8.self),
                count: count
            )
        }
        return count
    }

    func waitForProgress(operationID: Int, timeout: TimeInterval) -> Bool {
        let progress = lock.withLock { () -> DispatchSemaphore? in
            guard activeOperationID == operationID, !finished else { return nil }
            return progressSemaphore
        }
        guard let progress else { return false }
        return progress.wait(timeout: .now() + max(timeout, 0)) == .success
    }

    func cancel() {
        let task = lock.withLock { activeTask }
        task?.cancel()
        if let task {
            finish(BunnyNativeDecoderError.stopped, taskIdentifier: task.taskIdentifier)
        }
    }

    /// Ends this fetcher's reusable URLSession while the owner still retains
    /// the delegate. Constructing or invalidating a lazy session from
    /// `deinit` races URLSession's asynchronous delegate-finalization callback
    /// and can dereference an object that is already being destroyed.
    func invalidate() {
        cancel()
        let session = sessionLock.withLock { () -> URLSession? in
            guard !sessionInvalidated else { return nil }
            sessionInvalidated = true
            defer { sessionStorage = nil }
            return sessionStorage
        }
        session?.invalidateAndCancel()
    }

    private func makeTask(with request: URLRequest) throws -> URLSessionDataTask {
        try sessionLock.withLock {
            guard !sessionInvalidated else { throw BunnyNativeDecoderError.stopped }
            let session: URLSession
            if let existing = sessionStorage {
                session = existing
            } else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 30
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.httpMaximumConnectionsPerHost = 2
                session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                sessionStorage = session
            }
            return session.dataTask(with: request)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard lock.withLock({ activeTaskIdentifier == task.taskIdentifier }) else {
            completionHandler(nil)
            return
        }
        guard let url = request.url else {
            finish(
                BunnyNativeDecoderError.invalidSource("a redirect omitted its destination"),
                taskIdentifier: task.taskIdentifier
            )
            completionHandler(nil)
            return
        }
        do {
            try policy.validateRequestURL(url)
            completionHandler(
                PlaybackRangeRedirectPolicy.request(
                    preservingHeadersFrom: task.currentRequest ?? task.originalRequest,
                    for: request
                )
            )
        } catch {
            finish(error, taskIdentifier: task.taskIdentifier)
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock {
            guard activeTaskIdentifier == dataTask.taskIdentifier else { return }
            self.response = response as? HTTPURLResponse
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard activeTaskIdentifier == dataTask.taskIdentifier else {
            lock.unlock()
            return
        }
        let remaining = max(maximumBytes - received.count, 0)
        if remaining > 0 {
            received.append(data.prefix(remaining))
        }
        let complete = received.count >= maximumBytes
        let progress = progressSemaphore
        lock.unlock()
        progress.signal()
        if complete {
            dataTask.cancel()
            finish(
                BunnyNativeDecoderError.network("response exceeded the byte limit"),
                taskIdentifier: dataTask.taskIdentifier
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let code = (error as? URLError)?.code.rawValue
            finish(
                BunnyNativeDecoderError.network(
                    code.map { "network error \($0)" } ?? "network request failed"
                ),
                taskIdentifier: task.taskIdentifier
            )
        } else {
            finish(nil, taskIdentifier: task.taskIdentifier)
        }
    }

    private func finish(_ error: Error?, taskIdentifier: Int) {
        lock.lock()
        guard activeTaskIdentifier == taskIdentifier, !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let error {
            failure = error
        }
        let progress = progressSemaphore
        lock.unlock()
        progress.signal()
        semaphore.signal()
    }
}

private final class BunnyMediaRangeReader: @unchecked Sendable {
    private struct Chunk {
        let offset: UInt64
        let data: Data

        func contains(_ offset: UInt64) -> Bool {
            offset >= self.offset && offset < self.offset + UInt64(data.count)
        }
    }

    private struct PrefetchState {
        var generation = 0
        var range: Range<UInt64>?
        var result: Result<Chunk, Error>?
        var waiter: DispatchSemaphore?
    }

    private enum PrefetchLookup {
        case copied(Int)
        case ready(Chunk)
        case pending(Range<UInt64>)
        case unavailable
    }

    let sourceLength: UInt64

    private var requestURL: URL
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var fileHandle: FileHandle?
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var readsSuspendedForSeek = false
    private var prioritizedSeekPrefetchWindows = 0
    private let remotePolicy: BunnyRemoteSourcePolicy?
    private let remoteFetch: BunnyRangeFetch?
    private let prefetchFetches: [BunnyRangeFetch]
    private let prefetchQueues: [DispatchQueue]
    private let prefetchLock = NSLock()
    private var prefetchStates: [PrefetchState]
    private let maximumRetainedCacheBytes: Int
    private let onBlockingRead: @Sendable (_ force: Bool) -> Bool

    init(
        url: URL,
        trustedPrivateNetworkOrigin: URL?,
        onBlockingRead: @escaping @Sendable (_ force: Bool) -> Bool
    ) throws {
        requestURL = url
        self.onBlockingRead = onBlockingRead
        if url.isFileURL {
            remotePolicy = nil
            remoteFetch = nil
            prefetchFetches = []
            prefetchQueues = []
            prefetchStates = []
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize > 0 else {
                throw BunnyNativeDecoderError.invalidSource("empty local file")
            }
            sourceLength = UInt64(fileSize)
            maximumRetainedCacheBytes = PlaybackRangeChunkPolicy
                .maximumRetainedCacheBytes(sourceLength: sourceLength)
            fileHandle = try FileHandle(forReadingFrom: url)
        } else {
            let policy = try BunnyRemoteSourcePolicy(
                sourceURL: url,
                trustedPrivateOrigin: trustedPrivateNetworkOrigin
            )
            remotePolicy = policy
            let fetch = BunnyRangeFetch(policy: policy)
            remoteFetch = fetch
            do {
                var request = URLRequest(url: url)
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let result = try fetch.run(request, maximumBytes: 2)
                guard result.response.statusCode == 206 else {
                    throw BunnyNativeDecoderError.network("HTTP \(result.response.statusCode)")
                }
                guard result.data.count == 1,
                      let contentRange = BunnyContentRange(
                        result.response.value(forHTTPHeaderField: "Content-Range")
                      ),
                      contentRange.lowerBound == 0,
                      contentRange.upperBound == 0
                else {
                    throw BunnyNativeDecoderError.network("invalid byte-range response")
                }
                sourceLength = contentRange.totalLength
                if let resolvedURL = result.response.url {
                    try policy.validateRequestURL(resolvedURL)
                    requestURL = resolvedURL
                }
            } catch {
                fetch.invalidate()
                throw error
            }
            let prefetchDepth = PlaybackRangeChunkPolicy.prefetchDepth(
                sourceLength: sourceLength
            )
            maximumRetainedCacheBytes = PlaybackRangeChunkPolicy
                .maximumRetainedCacheBytes(sourceLength: sourceLength)
            prefetchFetches = (0..<prefetchDepth).map { _ in
                BunnyRangeFetch(policy: policy)
            }
            prefetchQueues = (0..<prefetchDepth).map { index in
                DispatchQueue(
                    label: "app.temustremio.bunny-native.prefetch.\(index)",
                    qos: .userInitiated
                )
            }
            prefetchStates = Array(
                repeating: PrefetchState(),
                count: prefetchDepth
            )
            NSLog(
                "BUNNY_RANGE_POLICY source_bytes=%llu prefetch_depth=%d cache_bytes=%d maximum_bytes=%d",
                sourceLength,
                prefetchDepth,
                maximumRetainedCacheBytes,
                PlaybackRangeChunkPolicy.maximumBufferedBytes(sourceLength: sourceLength)
            )
        }
    }

    deinit {
        cancel()
        try? fileHandle?.close()
    }

    func cancel() {
        cancellationLock.withLock {
            cancelled = true
            readsSuspendedForSeek = true
        }
        cancelPrefetch()
        remoteFetch?.invalidate()
        prefetchFetches.forEach { $0.invalidate() }
    }

    /// Breaks a blocking range request without permanently closing the media
    /// source. The decoder uses this when a seek supersedes work for the old
    /// playback position, then immediately reuses the reader at the new one.
    func interruptForSeek() {
        cancellationLock.withLock {
            readsSuspendedForSeek = true
        }
        remoteFetch?.cancel()
        cancelPrefetch()
    }

    func resumeAfterSeekInterrupt(prioritizeRandomAccess: Bool = false) {
        cancellationLock.withLock {
            guard !cancelled else { return }
            readsSuspendedForSeek = false
            prioritizedSeekPrefetchWindows = prioritizeRandomAccess ? 1 : 0
        }
    }

    func read(offset: UInt64, output: UnsafeMutablePointer<UInt8>, length: Int) -> Int64 {
        guard length > 0, offset < sourceLength else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        do {
            var copied = 0
            while copied < length {
                guard cancellationLock.withLock({
                    !cancelled && !readsSuspendedForSeek
                }) else {
                    throw BunnyNativeDecoderError.stopped
                }
                let copiedBeforeIteration = copied
                let absolute = offset + UInt64(copied)
                guard absolute < sourceLength else { break }
                if requestURL.isFileURL {
                    guard let fileHandle else { return -1 }
                    try fileHandle.seek(toOffset: absolute)
                    let wanted = min(length - copied, Int(sourceLength - absolute))
                    guard let data = try fileHandle.read(upToCount: wanted), !data.isEmpty else { break }
                    data.copyBytes(to: output.advanced(by: copied), count: data.count)
                    copied += data.count
                    continue
                }

                if let index = chunks.firstIndex(where: { $0.contains(absolute) }) {
                    let chunk = chunks.remove(at: index)
                    chunks.insert(chunk, at: 0)
                    let relative = Int(absolute - chunk.offset)
                    let count = min(length - copied, chunk.data.count - relative)
                    chunk.data.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { return }
                        output.advanced(by: copied).update(
                            from: base.advanced(by: relative).assumingMemoryBound(to: UInt8.self),
                            count: count
                        )
                    }
                    copied += count
                    continue
                }

                // Keep startup metadata reads small, then amortize request
                // latency over larger chunks for high-bitrate 40GB+ sources.
                // Eight retained 2MiB chunks were too request-bound for a
                // ~68Mbps remux. Two speculative 8MiB ranges hide request
                // jitter while the aggregate reader remains bounded to 64MiB.
                switch takePrefetchedChunk(
                    containing: absolute,
                    output: output.advanced(by: copied),
                    maximumLength: length - copied
                ) {
                case let .copied(count):
                    copied += count
                    if let consumedRange = PlaybackRangeChunkPolicy.byteRange(
                        containing: absolute,
                        sourceLength: sourceLength
                    ), absolute + UInt64(count) >= consumedRange.upperBound {
                        schedulePrefetchWindow(afterConsumedRange: consumedRange)
                    }
                    continue
                case let .ready(prefetched):
                    retainChunk(prefetched)
                    schedulePrefetchWindow(after: prefetched)
                    continue
                case let .pending(pendingRange):
                    // Do not let one slow speculative response block ordered
                    // demuxing while later ranges are already complete. A
                    // small foreground bridge keeps roughly the same request
                    // geometry as metadata reads and leaves the full prefetch
                    // in flight for the remainder of its range.
                    if let bridgeRange = PlaybackRangeChunkPolicy.foregroundBridgeRange(
                        startingAt: absolute,
                        within: pendingRange,
                        sourceLength: sourceLength
                    ) {
                        let bridge = try fetchChunk(
                            offset: bridgeRange.lowerBound,
                            length: bridgeRange.count,
                            purpose: "bridge"
                        )
                        guard !bridge.data.isEmpty else { break }
                        retainChunk(bridge)
                        continue
                    }
                case .unavailable:
                    break
                }

                guard let range = PlaybackRangeChunkPolicy.byteRange(
                    containing: absolute,
                    sourceLength: sourceLength
                ) else { break }
                let isMetadataPrefix = range.lowerBound == 0
                // Begin following streaming ranges while an ordinary body
                // request is still in flight. The metadata prefix is the one
                // exception: fetch it first, then immediately seed the first
                // body window so parallel reads do not delay container setup.
                if !isMetadataPrefix {
                    schedulePrefetchWindow(afterConsumedRange: range)
                }
                _ = onBlockingRead(true)
                let chunk = try fetchChunk(
                    offset: range.lowerBound,
                    length: range.count
                )
                guard !chunk.data.isEmpty else { break }
                retainChunk(chunk)
                if isMetadataPrefix {
                    schedulePrefetchWindow(afterConsumedRange: range)
                }
                guard copied > copiedBeforeIteration || chunk.contains(absolute) else {
                    throw BunnyNativeDecoderError.network("byte-range reader made no progress")
                }
            }
            return Int64(copied)
        } catch {
            return -1
        }
    }

    private func retainChunk(_ chunk: Chunk) {
        chunks.removeAll { existing in
            existing.offset == chunk.offset
        }
        chunks.insert(chunk, at: 0)
        var retainedBytes = chunks.reduce(0) { $0 + $1.data.count }
        while retainedBytes > maximumRetainedCacheBytes,
              chunks.count > 1 {
            retainedBytes -= chunks.removeLast().data.count
        }
    }

    private func fetchChunk(
        offset: UInt64,
        length: Int,
        using fetchOverride: BunnyRangeFetch? = nil,
        purpose: String = "read",
        operationID: Int? = nil
    ) throws -> Chunk {
        guard remotePolicy != nil,
              let fetch = fetchOverride ?? remoteFetch
        else {
            throw BunnyNativeDecoderError.invalidSource("missing remote source client")
        }
        let end = offset + UInt64(max(length - 1, 0))
        var request = URLRequest(url: requestURL)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var lastError: Error?
        for attempt in 1...3 {
            try cancellationLock.withLock {
                guard !cancelled else { throw BunnyNativeDecoderError.stopped }
            }
            do {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let result = try fetch.run(
                    request,
                    maximumBytes: length + 1,
                    startGuard: { [weak self] in
                        guard let self else { return false }
                        return self.cancellationLock.withLock {
                            !self.cancelled && !self.readsSuspendedForSeek
                        }
                    },
                    operationID: operationID
                )
                guard result.response.statusCode == 206 else {
                    throw BunnyNativeDecoderError.network("server ignored byte-range request")
                }
                guard result.data.count == length,
                      let contentRange = BunnyContentRange(
                        result.response.value(forHTTPHeaderField: "Content-Range")
                      ),
                      contentRange.lowerBound == offset,
                      contentRange.upperBound == end,
                      contentRange.totalLength == sourceLength
                else {
                    throw BunnyNativeDecoderError.network("invalid byte-range response")
                }
                let elapsedMilliseconds = max(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                    0.1
                )
                if elapsedMilliseconds >= 250 {
                    let megabitsPerSecond = Double(result.data.count) * 8 / 1_000
                        / elapsedMilliseconds
                    NSLog(
                        "BUNNY_RANGE_FETCH purpose=%@ offset=%llu bytes=%ld ms=%.1f mbps=%.1f",
                        purpose,
                        offset,
                        result.data.count,
                        elapsedMilliseconds,
                        megabitsPerSecond
                    )
                }
                return Chunk(offset: offset, data: result.data)
            } catch let error as BunnyNativeDecoderError {
                if case .stopped = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            if attempt < 3 {
                NSLog(
                    "BUNNY_RANGE retry=%d offset=%llu length=%d error=%@",
                    attempt,
                    offset,
                    length,
                    lastError?.localizedDescription ?? "unknown"
                )
            }
        }
        if let lastError {
            throw lastError
        }
        throw BunnyNativeDecoderError.network("byte-range request failed")
    }

    private func schedulePrefetchWindow(after chunk: Chunk) {
        schedulePrefetchWindow(
            afterConsumedRange: chunk.offset..<(chunk.offset + UInt64(chunk.data.count))
        )
    }

    private func schedulePrefetchWindow(afterConsumedRange consumedRange: Range<UInt64>) {
        guard !prefetchFetches.isEmpty else { return }
        let requestedDepth = cancellationLock.withLock { () -> Int in
            guard prioritizedSeekPrefetchWindows > 0 else {
                return prefetchFetches.count
            }
            prioritizedSeekPrefetchWindows -= 1
            return PlaybackRangeChunkPolicy.initialSeekPrefetchDepth(
                sourceLength: sourceLength
            )
        }
        let desiredRanges = PlaybackRangeChunkPolicy.prefetchRanges(
            after: consumedRange,
            sourceLength: sourceLength,
            depth: requestedDepth
        )
        guard !desiredRanges.isEmpty else { return }

        struct Work {
            let slot: Int
            let generation: Int
            let range: Range<UInt64>
        }
        var work: [Work] = []
        var cancelledSlots: [Int] = []
        var releasedWaiters: [DispatchSemaphore] = []

        prefetchLock.lock()
        for slot in prefetchStates.indices {
            guard let existingRange = prefetchStates[slot].range,
                  !desiredRanges.contains(existingRange)
            else { continue }
            prefetchStates[slot].generation &+= 1
            prefetchStates[slot].range = nil
            prefetchStates[slot].result = nil
            if let waiter = prefetchStates[slot].waiter {
                releasedWaiters.append(waiter)
                prefetchStates[slot].waiter = nil
            }
            cancelledSlots.append(slot)
        }

        for range in desiredRanges {
            guard !prefetchStates.contains(where: { $0.range == range }),
                  let slot = prefetchStates.firstIndex(where: { $0.range == nil })
            else { continue }
            prefetchStates[slot].generation &+= 1
            prefetchStates[slot].range = range
            prefetchStates[slot].result = nil
            prefetchStates[slot].waiter = nil
            work.append(
                Work(
                    slot: slot,
                    generation: prefetchStates[slot].generation,
                    range: range
                )
            )
        }
        prefetchLock.unlock()

        releasedWaiters.forEach { $0.signal() }
        cancelledSlots.forEach { prefetchFetches[$0].cancel() }
        for item in work {
            let fetch = prefetchFetches[item.slot]
            prefetchQueues[item.slot].async { [weak self] in
                guard let self else { return }
                guard self.prefetchLock.withLock({
                    self.prefetchStates[item.slot].generation == item.generation
                        && self.prefetchStates[item.slot].range == item.range
                }) else { return }
                let result: Result<Chunk, Error>
                do {
                    result = .success(
                        try self.fetchChunk(
                            offset: item.range.lowerBound,
                            length: item.range.count,
                            using: fetch,
                            purpose: "prefetch",
                            operationID: item.generation
                        )
                    )
                } catch {
                    result = .failure(error)
                }
                var waiter: DispatchSemaphore?
                self.prefetchLock.withLock {
                    guard self.prefetchStates[item.slot].generation == item.generation,
                          self.prefetchStates[item.slot].range == item.range
                    else { return }
                    self.prefetchStates[item.slot].result = result
                    waiter = self.prefetchStates[item.slot].waiter
                    self.prefetchStates[item.slot].waiter = nil
                }
                waiter?.signal()
            }
        }
    }

    private func takePrefetchedChunk(
        containing offset: UInt64,
        output: UnsafeMutablePointer<UInt8>,
        maximumLength: Int
    ) -> PrefetchLookup {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var reportedBlockingRead = false
        while true {
            var expectedSlot: Int?
            var expectedGeneration = 0
            var expectedRange: Range<UInt64>?

            prefetchLock.lock()
            guard let slot = prefetchStates.firstIndex(where: { state in
                state.range?.contains(offset) == true
            }), let range = prefetchStates[slot].range else {
                prefetchLock.unlock()
                return .unavailable
            }
            if let result = prefetchStates[slot].result {
                prefetchStates[slot].range = nil
                prefetchStates[slot].result = nil
                prefetchStates[slot].waiter = nil
                prefetchLock.unlock()
                guard case let .success(chunk) = result else { return .unavailable }
                return .ready(chunk)
            }
            expectedSlot = slot
            expectedGeneration = prefetchStates[slot].generation
            expectedRange = range
            prefetchLock.unlock()

            let relativeOffset = Int(offset - range.lowerBound)
            if let copied = prefetchFetches[slot].copyReceived(
                operationID: expectedGeneration,
                relativeOffset: relativeOffset,
                to: output,
                maximumLength: maximumLength
            ), copied > 0 {
                return .copied(copied)
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let grace = TimeInterval(
                PlaybackRangeChunkPolicy.prefetchCompletionGraceMilliseconds(
                    sourceLength: sourceLength
                )
            ) / 1_000
            if elapsed < grace {
                if elapsed >= 0.10, !reportedBlockingRead {
                    reportedBlockingRead = onBlockingRead(false)
                }
                _ = prefetchFetches[slot].waitForProgress(
                    operationID: expectedGeneration,
                    timeout: min(0.10, max(grace - elapsed, 0))
                )
                continue
            }

            prefetchLock.lock()
            guard let expectedSlot,
                  prefetchStates[expectedSlot].generation == expectedGeneration,
                  prefetchStates[expectedSlot].range == expectedRange
            else {
                prefetchLock.unlock()
                return .unavailable
            }
            prefetchStates[expectedSlot].waiter = nil
            if let result = prefetchStates[expectedSlot].result {
                prefetchStates[expectedSlot].range = nil
                prefetchStates[expectedSlot].result = nil
                prefetchLock.unlock()
                guard case let .success(chunk) = result else { return .unavailable }
                return .ready(chunk)
            }
            prefetchLock.unlock()
            if let expectedRange {
                if !reportedBlockingRead {
                    _ = onBlockingRead(true)
                }
                NSLog(
                    "BUNNY_RANGE bridge_required offset=%llu pending_lower=%llu pending_upper=%llu",
                    offset,
                    expectedRange.lowerBound,
                    expectedRange.upperBound
                )
                return .pending(expectedRange)
            } else {
                return .unavailable
            }
        }
    }

    private func cancelPrefetch() {
        var waiters: [DispatchSemaphore] = []
        prefetchLock.lock()
        for slot in prefetchStates.indices {
            prefetchStates[slot].generation &+= 1
            prefetchStates[slot].range = nil
            prefetchStates[slot].result = nil
            if let waiter = prefetchStates[slot].waiter {
                waiters.append(waiter)
                prefetchStates[slot].waiter = nil
            }
        }
        prefetchLock.unlock()
        waiters.forEach { $0.signal() }
        prefetchFetches.forEach { $0.cancel() }
    }
}

private let bunnyNativeReadAt: @convention(c) (
    UnsafeMutableRawPointer?,
    UInt64,
    UnsafeMutablePointer<UInt8>?,
    Int
) -> Int64 = { context, offset, output, length in
    guard let context, let output else { return -1 }
    let reader = Unmanaged<BunnyMediaRangeReader>.fromOpaque(context).takeUnretainedValue()
    return reader.read(offset: offset, output: output, length: length)
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

private struct BunnyNativePacket: @unchecked Sendable {
    let trackIndex: Int
    let presentationTime: CMTime
    let decodeTime: CMTime
    let duration: CMTime
    let flags: UInt32
    let data: Data
    let hdr10PlusData: Data?
}

private struct BunnyRawMediaPacket: @unchecked Sendable {
    let trackIndex: Int
    let presentationTimeNanoseconds: Int64
    let decodeTimeNanoseconds: Int64
    let durationNanoseconds: UInt64
    let flags: UInt32
    let data: Data
    let hdr10PlusData: Data?
}

private enum BunnyPacketReadResult: @unchecked Sendable {
    case packet(BunnyRawMediaPacket)
    case endOfStream
    case failure(String)
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

    /// The reader must be interrupted before this call when a seek or track
    /// selection needs exclusive access to the Rust session. A completed
    /// result is returned so a track-only change can retain packets belonging
    /// to unaffected tracks. Seeks and shutdown deliberately discard it via
    /// `pauseAndWait()`.
    func pauseAndTakeResult() -> BunnyPacketReadResult? {
        lock.withLock {
            active = false
        }
        queue.sync {}
        return lock.withLock {
            generation &+= 1
            inFlight = false
            defer { pendingResult = nil }
            return pendingResult
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
                  raw.abi_version == 3,
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

private struct BunnyNativePacketReservoir {
    private struct Entry {
        let packet: BunnyNativePacket
        let kind: UInt32
        let timelineStart: TimeInterval
        let timelineEnd: TimeInterval
    }

    private var entries: [Entry?] = []
    private var firstLiveIndex = 0
    private(set) var byteCount = 0
    private(set) var packetCount = 0
    private var videoPacketCount = 0
    private var audioPacketCount = 0
    private var subtitlePacketCount = 0
    private var firstTimelineStart: TimeInterval?
    private var latestTimelineEnd: TimeInterval?
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
        guard let firstTimelineStart, let latestTimelineEnd else { return 0 }
        return max(latestTimelineEnd - firstTimelineStart, 0)
    }

    var isFull: Bool {
        PlaybackCompressedPacketBufferPolicy.isFull(
            byteCount: byteCount,
            packetCount: packetCount,
            bufferedDuration: bufferedDuration,
            limits: limits
        )
    }

    var observedVideoDecodeSpan: TimeInterval {
        guard let firstObservedVideoDecodeTime,
              let latestObservedVideoDecodeTime
        else { return 0 }
        return max(latestObservedVideoDecodeTime - firstObservedVideoDecodeTime, 0)
    }

    var videoTimingCalibrationReady: Bool {
        PlaybackBufferingPolicy.videoTimingCalibrationReady(
            keyframeCount: observedVideoKeyframeCount,
            packetCount: observedVideoPacketCount,
            decodeSpan: observedVideoDecodeSpan,
            reservoirIsFull: isFull
        )
    }

    mutating func append(_ packet: BunnyNativePacket, kind: UInt32) {
        let presentationTime = packet.presentationTime.seconds
        let decodeTime = packet.decodeTime.seconds
        let duration = packet.duration.seconds
        let timelineStart = decodeTime.isFinite
            ? decodeTime
            : (presentationTime.isFinite ? presentationTime : latestTimelineEnd ?? 0)
        let timelineEnd = presentationTime.isFinite
            ? presentationTime + max(duration.isFinite ? duration : 0, 0)
            : timelineStart
        entries.append(Entry(
            packet: packet,
            kind: kind,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
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
        if firstTimelineStart == nil {
            firstTimelineStart = timelineStart
        }
        latestTimelineEnd = max(latestTimelineEnd ?? timelineEnd, timelineEnd)
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
        firstTimelineStart = nil
        latestTimelineEnd = nil
        observedVideoPacketCount = 0
        observedVideoKeyframeCount = 0
        maximumObservedVideoDecodeLag = 0
        firstObservedVideoDecodeTime = nil
        latestObservedVideoDecodeTime = nil
    }

    mutating func removeAll(kind: UInt32) {
        let retained = entries.compactMap { $0 }.filter { $0.kind != kind }
        entries = retained.map(Optional.some)
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
        firstTimelineStart = retained.first?.timelineStart
        latestTimelineEnd = retained.map(\.timelineEnd).max()
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
            firstTimelineStart = firstLiveIndex < entries.count
                ? entries[firstLiveIndex]?.timelineStart
                : nil
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

private struct BunnyNativeSeekTransition {
    let targetTime: TimeInterval
    var videoReady: Bool
    var audioReady: Bool
    var isWaitingForVideoRandomAccessPoint: Bool
    var hiddenVideoFrames = 0
    var discardedAudioPackets = 0
    var discardedVideoPacketsBeforeRandomAccessPoint = 0

    init(targetTime: TimeInterval, hasVideo: Bool, hasAudio: Bool) {
        self.targetTime = targetTime
        videoReady = !hasVideo
        audioReady = !hasAudio
        isWaitingForVideoRandomAccessPoint = hasVideo
    }

    var isReady: Bool {
        videoReady && audioReady
    }
}

final class BunnyNativeDecoder: NSObject, @unchecked Sendable {
    let videoLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    var onOpen: ((BunnyNativeMediaInfo) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onSubtitle: ((String?, TimeInterval, TimeInterval) -> Void)?
    var onBitmapSubtitle: ((BunnyNativeBitmapSubtitleCue?, TimeInterval, TimeInterval) -> Void)?
    var onSeekCompleted: ((TimeInterval, Bool) -> Void)?
    var onMetrics: ((Int, Int, Int, TimeInterval, TimeInterval, TimeInterval) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    var currentTime: TimeInterval {
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
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
    private var started = false
    private var stopped = false
    private var desiredRate: Float = 0
    private var pendingSeek: TimeInterval?
    private var pendingAudioSelection: Int?
    private var pendingSubtitleSelection: Int?
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
    private var audioRendererFlushObserver: NSObjectProtocol?
    private let diagnosticsEnabled: Bool
    private let displayCadenceProbe: BunnyDisplayCadenceProbe?
    // Dolby layouts are encoded in the sync frame rather than Matroska's
    // channel-count field. This cache is confined to `worker`.
    private var dolbyFormatDescriptions: [Int: CMFormatDescription] = [:]
    private var reportedDolbyTimingMismatchTracks = Set<Int>()
    private var reportedHDR10PlusInput = false

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
            self?.recoverAfterAutomaticAudioRendererFlush()
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

    func seek(to time: TimeInterval) {
        stateLock.withLock {
            pendingSeek = max(time, 0)
            // Publish the pending seek and suspend old-position reads under the
            // same lock so the worker cannot observe one without the other.
            activeReader?.interruptForSeek()
        }
    }

    private func recoverAfterAutomaticAudioRendererFlush() {
        let recoveryTime = currentTime
        let scheduled = stateLock.withLock { () -> Bool in
            guard started, !stopped, let activeReader else { return false }
            pendingSeek = max(recoveryTime, 0)
            activeReader.interruptForSeek()
            return true
        }
        guard scheduled else { return }
        NSLog(
            "BUNNY_AUDIO_RENDERER automatic_flush recovery_time=%.3f",
            recoveryTime
        )
    }

    func selectAudioStreamIndex(_ streamIndex: Int) {
        stateLock.withLock {
            pendingAudioSelection = streamIndex
            activeReader?.interruptForSeek()
        }
    }

    func selectSubtitleStreamIndex(_ streamIndex: Int) {
        stateLock.withLock {
            pendingSubtitleSelection = streamIndex
            activeReader?.interruptForSeek()
        }
    }

    func stop() {
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
            guard summary.abi_version == 1 else {
                throw BunnyNativeDecoderError.core("unsupported media ABI")
            }
            var videoTracks = descriptors.filter {
                $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO)
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
                }
                playableVideoTracks = videoTracks.filter(Self.isApplePlayable)
            }
            let audioTracks = descriptors.filter {
                $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO)
            }
            let playableAudioTracks = audioTracks.filter(Self.isApplePlayable)
            let video = Self.defaultTrack(in: playableVideoTracks)
            let selectedAudio = Self.defaultTrack(in: playableAudioTracks)
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
            defer {
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
            var deferredReadResult: BunnyPacketReadResult?
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
                if let seek = takePendingSeek() {
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
                    let success = performSeek(
                        session: session,
                        pgsDecoder: pgsDecoder,
                        time: seek,
                        error: &error
                    )
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
                        publish { [weak self] in self?.onSeekCompleted?(seek, false) }
                    }
                    packetReadPump.resume()
                }
                let selectionChanges: (audio: Bool, subtitle: Bool)
                if hasPendingTrackSelection {
                    let completedReadResult = packetReadPump.pauseAndTakeResult()
                    reader.resumeAfterSeekInterrupt()
                    selectionChanges = applyPendingSelections(
                        session: session,
                        pgsDecoder: pgsDecoder,
                        descriptors: descriptors
                    )
                    if case let .packet(raw)? = completedReadResult,
                       let descriptor = descriptors[safe: raw.trackIndex],
                       PlaybackTrackSelectionPacketPolicy.preservesCompletedPacket(
                           kind: Self.packetTrackKind(descriptor.raw.kind),
                           audioSelectionChanged: selectionChanges.audio,
                           subtitleSelectionChanged: selectionChanges.subtitle
                       ) {
                        deferredReadResult = completedReadResult
                    } else if case .endOfStream? = completedReadResult {
                        deferredReadResult = completedReadResult
                    }
                    packetReadPump.resume()
                } else {
                    selectionChanges = (audio: false, subtitle: false)
                }
                if selectionChanges.audio {
                    packetReservoir.removeAll(kind: UInt32(STREMIO_MEDIA_TRACK_AUDIO))
                    isRefillingPacketReservoir = true
                }
                if selectionChanges.subtitle {
                    packetReservoir.removeAll(kind: UInt32(STREMIO_MEDIA_TRACK_SUBTITLE))
                    isRefillingPacketReservoir = true
                }
                let availableReadResult: BunnyPacketReadResult?
                if let completedReadResult = deferredReadResult {
                    availableReadResult = completedReadResult
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
                    if duration <= 0 || currentTime >= duration - 0.05 {
                        if !endPublished {
                            endPublished = true
                            publish { [weak self] in self?.onEnded?() }
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                let clock = currentTime
                let allowsLowReservePlayback =
                    ProcessInfo.processInfo.systemUptime < lowReservePlaybackDeadline
                if requiresPostSeekPreroll, !allowsLowReservePlayback {
                    // Advancing briefly releases hidden post-seek preroll
                    // samples. Once that bounded decoder grace expires, return
                    // to the normal 0.70-second preroll instead of continuing
                    // a large remote stream with only one or two frames queued.
                    isRebuffering = true
                    requiresPostSeekPreroll = false
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
                let videoDecodeHasCapacity = !hasVideo
                    || (videoDecompression?.canAcceptMore ?? false)
                let packet = packetReservoir.takeReady(
                    videoReady: compressedPrerollReady
                        && videoTimingCalibrated
                        && videoDecodeHasCapacity,
                    audioReady: compressedPrerollReady
                        && audioHasCapacity
                        && audioRenderer.isReadyForMoreMediaData
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
                                publish { [weak self] in
                                    self?.onSeekCompleted?(transition.targetTime, false)
                                }
                                seekTransition = nil
                            }
                            reachedEnd = true
                        } else {
                            Thread.sleep(forTimeInterval: 0.002)
                        }
                        continue
                    }
                    if packetReservoir.isFull {
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
                        var shouldDisplay = true
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
                    if var transition = seekTransition {
                        let isPreroll = PlaybackSeekTransitionPolicy
                            .sampleIsEntirelyBeforeTarget(
                                presentationTime: packet.presentationTime.seconds,
                                duration: packet.duration.seconds,
                                targetTime: transition.targetTime
                            )
                        if isPreroll {
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
                    let sample = try makeSampleBuffer(
                        packet: packet,
                        descriptor: descriptor,
                        videoDecodeLead: 0
                    )
                    audioRenderer.enqueue(sample)
                    renderedAudioFrames += 1
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
                        try publishPgsPacket(
                            packet,
                            decoder: pgsDecoder
                        )
                    } else {
                        let text = Self.normalizedSubtitleText(
                            packet.data,
                            codec: descriptor.raw.codec
                        )
                        publish { [weak self] in
                            self?.onSubtitle?(
                                text,
                                packet.presentationTime.seconds,
                                max(packet.duration.seconds, 0.1)
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
                  packet.abi_version == 3,
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
                additionalCodecAtoms: descriptor.additionalCodecAtoms
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
        }
        let info = BunnyNativeMediaInfo(
            duration: TimeInterval(summary.duration_ns) / 1_000_000_000,
            presentationSize: CGSize(
                width: Int(video?.raw.width ?? 0),
                height: Int(video?.raw.height ?? 0)
            ),
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
        descriptors: [BunnyNativeTrackDescriptor]
    ) -> (audio: Bool, subtitle: Bool) {
        let selections = stateLock.withLock { () -> (Int?, Int?) in
            defer {
                pendingAudioSelection = nil
                pendingSubtitleSelection = nil
            }
            return (pendingAudioSelection, pendingSubtitleSelection)
        }
        guard selections.0 != nil || selections.1 != nil else {
            return (audio: false, subtitle: false)
        }
        var audioChanged = false
        var subtitleChanged = false
        if let audio = selections.0 {
            if let descriptor = descriptors.first(where: {
                Int($0.raw.index) == audio && Self.isApplePlayable($0)
            }), stremio_media_select_track(
                session,
                UInt32(STREMIO_MEDIA_TRACK_AUDIO),
                Int32(audio)
            ) == 1 {
                audioChanged = true
                audioRenderer.flush()
                configureAudioRenderer(for: descriptor)
                publish {
                    PlaybackAudioSession.configurePlaybackContent(
                        channelCount: Int(descriptor.raw.channels)
                    )
                }
            }
        }
        if let subtitle = selections.1 {
            subtitleChanged = stremio_media_select_track(
                session,
                UInt32(STREMIO_MEDIA_TRACK_SUBTITLE),
                Int32(subtitle)
            ) == 1
            stremio_pgs_decoder_reset(pgsDecoder)
            publish { [weak self] in
                self?.onSubtitle?(nil, self?.currentTime ?? 0, 0)
                self?.onBitmapSubtitle?(nil, self?.currentTime ?? 0, 0)
            }
        }
        return (audio: audioChanged, subtitle: subtitleChanged)
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
        error: inout [CChar]
    ) -> Bool {
        synchronizer.setRate(0, time: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
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
        let nanoseconds = UInt64(max(time, 0) * 1_000_000_000)
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
        publish { [weak self] in
            self?.onSeekCompleted?(completed.targetTime, true)
        }
        return true
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
        decoder: OpaquePointer
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

        let presentation = stremio_pgs_presentation(decoder)
        let start = TimeInterval(presentation.presentation_time_ns) / 1_000_000_000
        let duration = max(packet.duration.seconds, 0.1)
        if presentation.is_clear != 0 {
            publish { [weak self] in self?.onBitmapSubtitle?(nil, start, 0) }
            return
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
        publish { [weak self] in self?.onBitmapSubtitle?(cue, start, duration) }
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

    private func takePendingSeek() -> TimeInterval? {
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

    private static func isApplePlayable(_ descriptor: BunnyNativeTrackDescriptor) -> Bool {
        descriptor.raw.flags & UInt32(STREMIO_MEDIA_TRACK_APPLE_DECODABLE) != 0
            && descriptor.formatDescription != nil
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
        var extensions = videoFormatExtensions(videoColor)
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
                additionalCodecAtoms: additionalCodecAtoms
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
        case UInt32(STREMIO_MEDIA_CODEC_AAC): (kAudioFormatMPEG4AAC, 1_024)
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
    additionalCodecAtoms: [String: Data]
) -> CMVideoFormatDescription? {
    guard let parsed = parseHEVCParameterSets(configuration) else { return nil }
    return makeHEVCFormatDescription(
        parameterSets: parsed.parameterSets,
        nalUnitHeaderLength: parsed.nalUnitHeaderLength,
        color: color,
        additionalCodecAtoms: additionalCodecAtoms
    )
}

private func makeHEVCFormatDescription(
    parameterSets: [Data],
    nalUnitHeaderLength: Int32,
    color: StremioMediaVideoColorInfo?,
    additionalCodecAtoms: [String: Data]
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
    var pointers = allocated.map { UnsafePointer($0) }
    var sizes = parameterSets.map(\.count)
    var extensions = videoFormatExtensions(color)
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
    _ color: StremioMediaVideoColorInfo?
) -> [String: Any] {
    guard let color, color.abi_version == 1 else { return [:] }
    var extensions = [String: Any]()
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
