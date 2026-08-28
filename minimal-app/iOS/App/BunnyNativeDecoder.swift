import AVFoundation
import CoreAudioTypes
import CoreMedia
import Darwin
import Foundation
import UIKit

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
    private var maximumBytes = 1
    private var semaphore = DispatchSemaphore(value: 0)
    private var received = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var finished = false
    private var activeTask: URLSessionDataTask?
    private var activeTaskIdentifier: Int?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(policy: BunnyRemoteSourcePolicy) {
        self.policy = policy
    }

    deinit {
        session.invalidateAndCancel()
    }

    func run(
        _ request: URLRequest,
        maximumBytes: Int,
        timeout: TimeInterval = 30,
        startGuard: (() -> Bool)? = nil
    ) throws -> Result {
        guard let url = request.url else {
            throw BunnyNativeDecoderError.invalidSource("the media request has no URL")
        }
        try policy.validateRequestURL(url)
        let requestSemaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request)
        let shouldStart = lock.withLock { () -> Bool in
            self.maximumBytes = max(maximumBytes, 1)
            semaphore = requestSemaphore
            received = Data()
            response = nil
            failure = nil
            finished = false
            activeTask = task
            activeTaskIdentifier = task.taskIdentifier
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

    func cancel() {
        let task = lock.withLock { activeTask }
        task?.cancel()
        if let task {
            finish(BunnyNativeDecoderError.stopped, taskIdentifier: task.taskIdentifier)
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
            completionHandler(request)
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
        lock.unlock()
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
        lock.unlock()
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

    let sourceLength: UInt64

    private var requestURL: URL
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var fileHandle: FileHandle?
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var readsSuspendedForSeek = false
    private let remotePolicy: BunnyRemoteSourcePolicy?
    private let remoteFetch: BunnyRangeFetch?
    private let prefetchFetches: [BunnyRangeFetch]
    private let prefetchQueues: [DispatchQueue]
    private let prefetchLock = NSLock()
    private var prefetchStates: [PrefetchState]

    init(url: URL, trustedPrivateNetworkOrigin: URL?) throws {
        requestURL = url
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
            fileHandle = try FileHandle(forReadingFrom: url)
        } else {
            let policy = try BunnyRemoteSourcePolicy(
                sourceURL: url,
                trustedPrivateOrigin: trustedPrivateNetworkOrigin
            )
            remotePolicy = policy
            let fetch = BunnyRangeFetch(policy: policy)
            remoteFetch = fetch
            prefetchFetches = (0..<PlaybackRangeChunkPolicy.prefetchDepth).map { _ in
                BunnyRangeFetch(policy: policy)
            }
            prefetchQueues = (0..<PlaybackRangeChunkPolicy.prefetchDepth).map { index in
                DispatchQueue(
                    label: "app.temustremio.bunny-native.prefetch.\(index)",
                    qos: .userInitiated
                )
            }
            prefetchStates = Array(
                repeating: PrefetchState(),
                count: PlaybackRangeChunkPolicy.prefetchDepth
            )
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
        remoteFetch?.cancel()
        cancelPrefetch()
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

    func resumeAfterSeekInterrupt() {
        cancellationLock.withLock {
            guard !cancelled else { return }
            readsSuspendedForSeek = false
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
                if let prefetched = takePrefetchedChunk(containing: absolute) {
                    retainChunk(prefetched)
                    schedulePrefetchWindow(after: prefetched)
                    continue
                }

                guard let range = PlaybackRangeChunkPolicy.byteRange(
                    containing: absolute,
                    sourceLength: sourceLength
                ) else { break }
                // Begin the following ranges while the foreground request for
                // this range is still in flight. Starting only after the
                // current response completed was too late for immediate
                // post-seek demuxing.
                schedulePrefetchWindow(afterConsumedRange: range)
                let chunk = try fetchChunk(
                    offset: range.lowerBound,
                    length: range.count
                )
                guard !chunk.data.isEmpty else { break }
                retainChunk(chunk)
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
        while retainedBytes > PlaybackRangeChunkPolicy.maximumRetainedCacheBytes,
              chunks.count > 1 {
            retainedBytes -= chunks.removeLast().data.count
        }
    }

    private func fetchChunk(
        offset: UInt64,
        length: Int,
        using fetchOverride: BunnyRangeFetch? = nil,
        purpose: String = "read"
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
                    }
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
        guard consumedRange.count == Int(PlaybackRangeChunkPolicy.streamingChunkBytes),
              !prefetchFetches.isEmpty
        else { return }

        var desiredRanges: [Range<UInt64>] = []
        var nextOffset = consumedRange.upperBound
        for _ in 0..<PlaybackRangeChunkPolicy.prefetchDepth {
            guard let range = PlaybackRangeChunkPolicy.byteRange(
                containing: nextOffset,
                sourceLength: sourceLength
            ), range.count == Int(PlaybackRangeChunkPolicy.streamingChunkBytes)
            else { break }
            desiredRanges.append(range)
            nextOffset = range.upperBound
        }

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
                            purpose: "prefetch"
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

    private func takePrefetchedChunk(containing offset: UInt64) -> Chunk? {
        while true {
            var expectedSlot: Int?
            var expectedGeneration = 0
            var expectedRange: Range<UInt64>?

            prefetchLock.lock()
            guard let slot = prefetchStates.firstIndex(where: { state in
                state.range?.contains(offset) == true
            }), let range = prefetchStates[slot].range else {
                prefetchLock.unlock()
                return nil
            }
            if let result = prefetchStates[slot].result {
                prefetchStates[slot].range = nil
                prefetchStates[slot].result = nil
                prefetchStates[slot].waiter = nil
                prefetchLock.unlock()
                guard case let .success(chunk) = result else { return nil }
                return chunk
            }

            let semaphore = DispatchSemaphore(value: 0)
            prefetchStates[slot].waiter = semaphore
            expectedSlot = slot
            expectedGeneration = prefetchStates[slot].generation
            expectedRange = range
            prefetchLock.unlock()

            guard semaphore.wait(timeout: .now() + 31) == .success else {
                prefetchLock.withLock {
                    guard let expectedSlot,
                          prefetchStates[expectedSlot].generation == expectedGeneration,
                          prefetchStates[expectedSlot].range == expectedRange
                    else { return }
                    prefetchStates[expectedSlot].waiter = nil
                }
                return nil
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
    let codecID: String
    let name: String
    let language: String
    let formatDescription: CMFormatDescription?
}

private struct BunnyNativePacket: @unchecked Sendable {
    let trackIndex: Int
    let presentationTime: CMTime
    let duration: CMTime
    let flags: UInt32
    let data: Data
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
    private var storedMetricsSnapshot = BunnyNativeMetricsSnapshot.empty
    private var activeReader: BunnyMediaRangeReader?
    private var audioRendererFlushObserver: NSObjectProtocol?
    // Dolby layouts are encoded in the sync frame rather than Matroska's
    // channel-count field. This cache is confined to `worker`.
    private var dolbyFormatDescriptions: [Int: CMFormatDescription] = [:]
    private var reportedDolbyTimingMismatchTracks = Set<Int>()

    init(url: URL, trustedPrivateNetworkOrigin: URL? = nil) {
        self.url = url
        self.trustedPrivateNetworkOrigin = trustedPrivateNetworkOrigin
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
        synchronizer.addRenderer(videoLayer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.setRate(0, time: .zero)
        audioRendererFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: nil
        ) { [weak self] _ in
            self?.recoverAfterAutomaticAudioRendererFlush()
        }
    }

    deinit {
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
        stateLock.withLock { pendingAudioSelection = streamIndex }
    }

    func selectSubtitleStreamIndex(_ streamIndex: Int) {
        stateLock.withLock { pendingSubtitleSelection = streamIndex }
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
        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
    }

    private func run() {
        var session: OpaquePointer?
        do {
            let reader = try BunnyMediaRangeReader(
                url: url,
                trustedPrivateNetworkOrigin: trustedPrivateNetworkOrigin
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

            let descriptors = try loadTracks(session: session)
            let summary = stremio_media_summary(session)
            guard summary.abi_version == 1 else {
                throw BunnyNativeDecoderError.core("unsupported media ABI")
            }
            let videoTracks = descriptors.filter {
                $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_VIDEO)
            }
            let audioTracks = descriptors.filter {
                $0.raw.kind == UInt32(STREMIO_MEDIA_TRACK_AUDIO)
            }
            let playableVideoTracks = videoTracks.filter(Self.isApplePlayable)
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
                videoFormatReady = video?.formatDescription != nil
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

            var pendingPacket: BunnyNativePacket?
            var videoQueueEnd = 0.0
            var audioQueueEnd = 0.0
            var decodedVideoFrames = 0
            var renderedAudioFrames = 0
            var droppedVideoFrames = 0
            var lastMetricsAt = ProcessInfo.processInfo.systemUptime
            var reachedEnd = false
            var endPublished = false
            var seekTransition: BunnyNativeSeekTransition?
            var isRebuffering = true
            var lowReservePlaybackDeadline: TimeInterval = 0

            while !isStopped {
                if let seek = takePendingSeek() {
                    reader.resumeAfterSeekInterrupt()
                    // A newer seek may have arrived after this one was taken.
                    // Leave its interruption in force and skip obsolete work.
                    if hasPendingSeek { continue }
                    let success = performSeek(
                        session: session,
                        pgsDecoder: pgsDecoder,
                        time: seek,
                        error: &error
                    )
                    pendingPacket = nil
                    videoQueueEnd = seek
                    audioQueueEnd = seek
                    isRebuffering = true
                    storeMetricsSnapshot(
                        decodedVideoFrames: decodedVideoFrames,
                        droppedVideoFrames: droppedVideoFrames,
                        renderedAudioFrames: renderedAudioFrames,
                        videoQueueEnd: videoQueueEnd,
                        audioQueueEnd: audioQueueEnd
                    )
                    if success {
                        reachedEnd = false
                        endPublished = false
                        seekTransition = BunnyNativeSeekTransition(
                            targetTime: seek,
                            hasVideo: hasVideo,
                            hasAudio: hasAudio
                        )
                        if completeSeekTransitionIfReady(&seekTransition) {
                            isRebuffering = false
                            lowReservePlaybackDeadline =
                                ProcessInfo.processInfo.systemUptime + 0.25
                        }
                    } else {
                        seekTransition = nil
                        publish { [weak self] in self?.onSeekCompleted?(seek, false) }
                    }
                }
                applyPendingSelections(
                    session: session,
                    pgsDecoder: pgsDecoder,
                    descriptors: descriptors
                )

                if reachedEnd {
                    updateAppliedPlaybackRate(
                        isRebuffering: &isRebuffering,
                        videoQueueEnd: videoQueueEnd,
                        audioQueueEnd: audioQueueEnd,
                        hasVideo: hasVideo,
                        hasAudio: hasAudio,
                        nominalFrameRate: nominalFrameRate,
                        allowsLowReservePlayback: false,
                        reachedEnd: true
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
                let queuedEnd: TimeInterval
                if hasVideo, hasAudio {
                    // Keep both renderers covered. Using the furthest queue
                    // lets a long audio run stop demuxing while video drains.
                    queuedEnd = min(videoQueueEnd, audioQueueEnd)
                } else if hasVideo {
                    queuedEnd = videoQueueEnd
                } else {
                    queuedEnd = audioQueueEnd
                }
                updateAppliedPlaybackRate(
                    isRebuffering: &isRebuffering,
                    videoQueueEnd: videoQueueEnd,
                    audioQueueEnd: audioQueueEnd,
                    hasVideo: hasVideo,
                    hasAudio: hasAudio,
                    nominalFrameRate: nominalFrameRate,
                    allowsLowReservePlayback:
                        ProcessInfo.processInfo.systemUptime < lowReservePlaybackDeadline,
                    reachedEnd: false
                )
                if queuedEnd - clock > 8 {
                    Thread.sleep(forTimeInterval: 0.004)
                    continue
                }

                if pendingPacket == nil {
                    var raw = StremioMediaPacket()
                    let result = error.withUnsafeMutableBufferPointer { errorBuffer in
                        stremio_media_next_packet(
                            session,
                            &raw,
                            errorBuffer.baseAddress,
                            errorBuffer.count
                        )
                    }
                    // A seek can arrive while a remote packet read is blocked.
                    // Its intentional cancellation surfaces through the C ABI
                    // as a failed read; discard that obsolete packet operation
                    // and let the top of the loop process the pending seek.
                    if result != 1, hasPendingSeek {
                        pendingPacket = nil
                        continue
                    }
                    if result == 0 {
                        if let transition = seekTransition {
                            publish { [weak self] in
                                self?.onSeekCompleted?(transition.targetTime, false)
                            }
                            seekTransition = nil
                        }
                        reachedEnd = true
                        updateAppliedPlaybackRate(
                            isRebuffering: &isRebuffering,
                            videoQueueEnd: videoQueueEnd,
                            audioQueueEnd: audioQueueEnd,
                            hasVideo: hasVideo,
                            hasAudio: hasAudio,
                            nominalFrameRate: nominalFrameRate,
                            allowsLowReservePlayback: false,
                            reachedEnd: true
                        )
                        continue
                    }
                    guard result == 1, let bytes = raw.data else {
                        throw BunnyNativeDecoderError.core(Self.errorText(error))
                    }
                    guard raw.data_size <= 16 * 1024 * 1024 else {
                        throw BunnyNativeDecoderError.core("media packet exceeds the mobile safety limit")
                    }
                    let packetData = Data(bytes: bytes, count: raw.data_size)
                    let packetDuration = effectivePacketDuration(
                        rawDurationNanoseconds: raw.duration_ns,
                        trackIndex: Int(raw.track_index),
                        data: packetData,
                        descriptors: descriptors
                    )
                    pendingPacket = BunnyNativePacket(
                        trackIndex: Int(raw.track_index),
                        presentationTime: CMTime(
                            value: raw.presentation_time_ns,
                            timescale: 1_000_000_000
                        ),
                        duration: packetDuration,
                        flags: raw.flags,
                        data: packetData
                    )
                }

                guard let packet = pendingPacket,
                      let descriptor = descriptors[safe: packet.trackIndex]
                else {
                    pendingPacket = nil
                    continue
                }
                switch descriptor.raw.kind {
                case UInt32(STREMIO_MEDIA_TRACK_VIDEO):
                    let isKeyframe = packet.flags & UInt32(STREMIO_MEDIA_PACKET_KEYFRAME) != 0
                    if var transition = seekTransition {
                        if PlaybackSeekTransitionPolicy.shouldDiscardVideoBeforeRandomAccessPoint(
                            isKeyframe: isKeyframe,
                            isWaitingForRandomAccessPoint: transition.isWaitingForVideoRandomAccessPoint
                        ) {
                            transition.discardedVideoPacketsBeforeRandomAccessPoint += 1
                            seekTransition = transition
                            pendingPacket = nil
                            continue
                        }
                        if isKeyframe {
                            transition.isWaitingForVideoRandomAccessPoint = false
                        }
                        seekTransition = transition
                    }
                    if videoLayer.status == .failed {
                        throw videoLayer.error
                            ?? BunnyNativeDecoderError.formatDescription(descriptor.codecID)
                    }
                    guard videoLayer.isReadyForMoreMediaData else {
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }
                    do {
                        let sample = try makeSampleBuffer(packet: packet, descriptor: descriptor)
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
                            } else {
                                transition.videoReady = true
                            }
                            seekTransition = transition
                        }
                        videoLayer.enqueue(sample)
                        decodedVideoFrames += 1
                        let end = packet.presentationTime.seconds + packet.duration.seconds
                        if end.isFinite { videoQueueEnd = max(videoQueueEnd, end) }
                        if shouldDisplay {
                            scheduleFirstFrameCheck()
                        }
                        if completeSeekTransitionIfReady(&seekTransition) {
                            isRebuffering = false
                            lowReservePlaybackDeadline =
                                ProcessInfo.processInfo.systemUptime + 0.25
                        }
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
                            pendingPacket = nil
                            continue
                        }
                        transition.audioReady = true
                        seekTransition = transition
                    }
                    if audioRenderer.status == .failed {
                        throw audioRenderer.error
                            ?? BunnyNativeDecoderError.formatDescription(descriptor.codecID)
                    }
                    guard audioRenderer.isReadyForMoreMediaData else {
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }
                    let sample = try makeSampleBuffer(packet: packet, descriptor: descriptor)
                    audioRenderer.enqueue(sample)
                    renderedAudioFrames += 1
                    let end = packet.presentationTime.seconds + packet.duration.seconds
                    if end.isFinite { audioQueueEnd = max(audioQueueEnd, end) }
                    if completeSeekTransitionIfReady(&seekTransition) {
                        isRebuffering = false
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
                pendingPacket = nil

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
            let descriptor = BunnyNativeTrackDescriptor(
                raw: raw,
                codecPrivate: privateData,
                codecID: codecID,
                name: name,
                language: language,
                formatDescription: try makeFormatDescription(raw: raw, codecPrivate: privateData)
            )
            result.append(descriptor)
        }
        return result
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
    ) {
        let selections = stateLock.withLock { () -> (Int?, Int?) in
            defer {
                pendingAudioSelection = nil
                pendingSubtitleSelection = nil
            }
            return (pendingAudioSelection, pendingSubtitleSelection)
        }
        if let audio = selections.0 {
            if let descriptor = descriptors.first(where: {
                Int($0.raw.index) == audio && Self.isApplePlayable($0)
            }), stremio_media_select_track(
                session,
                UInt32(STREMIO_MEDIA_TRACK_AUDIO),
                Int32(audio)
            ) == 1 {
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
            _ = stremio_media_select_track(
                session,
                UInt32(STREMIO_MEDIA_TRACK_SUBTITLE),
                Int32(subtitle)
            )
            stremio_pgs_decoder_reset(pgsDecoder)
            publish { [weak self] in
                self?.onSubtitle?(nil, self?.currentTime ?? 0, 0)
                self?.onBitmapSubtitle?(nil, self?.currentTime ?? 0, 0)
            }
        }
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
        videoLayer.flush()
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
        reachedEnd: Bool
    ) {
        let desiredRate = stateLock.withLock { self.desiredRate }
        let previousRebuffering = isRebuffering
        let decision = PlaybackBufferingPolicy.decision(
            desiredRate: desiredRate,
            isRebuffering: isRebuffering,
            clock: currentTime,
            videoQueueEnd: videoQueueEnd,
            audioQueueEnd: audioQueueEnd,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            nominalFrameRate: nominalFrameRate,
            allowsLowReservePlayback: allowsLowReservePlayback,
            reachedEnd: reachedEnd
        )
        isRebuffering = decision.isRebuffering
        if PlaybackContinuityPolicy.requiresClockRateChange(
            currentRate: synchronizer.rate,
            requestedRate: decision.appliedRate
        ) {
            synchronizer.setRate(decision.appliedRate, time: synchronizer.currentTime())
        }
        if previousRebuffering != decision.isRebuffering, desiredRate > 0 {
            let reserve = PlaybackBufferingPolicy.commonReserve(
                clock: currentTime,
                videoQueueEnd: videoQueueEnd,
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
        descriptor: BunnyNativeTrackDescriptor
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
        var timing = CMSampleTimingInfo(
            duration: packet.duration.isValid && packet.duration > .zero ? packet.duration : .invalid,
            presentationTimeStamp: packet.presentationTime,
            decodeTimeStamp: .invalid
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
            if isReadyForDisplay {
                self.deliverFirstFrameOnce()
            } else if attempt < 80, self.videoLayer.status != .failed {
                self.scheduleFirstFrameCheck(
                    attempt: attempt + 1,
                    generation: generation
                )
            } else if self.videoLayer.status == .failed {
                self.stateLock.withLock {
                    if self.firstFrameCheckGeneration == generation {
                        self.firstFrameCheckScheduled = false
                    }
                }
                self.onFailure?(self.videoLayer.error ?? BunnyNativeDecoderError.formatDescription("video"))
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

    private func publish(_ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in action() }
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
        guard let (codec, atom) = codecAndAtom else { return nil }
        guard raw.width > 0,
              raw.height > 0,
              raw.width <= 16_384,
              raw.height <= 16_384,
              let width = Int32(exactly: raw.width),
              let height = Int32(exactly: raw.height)
        else { return nil }
        var description: CMVideoFormatDescription?
        let atoms: [String: Any] = codecPrivate.isEmpty ? [:] : [atom: codecPrivate]
        let extensions: [String: Any] = atoms.isEmpty ? [:] : [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms,
        ]
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr else { return nil }
        return description
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
