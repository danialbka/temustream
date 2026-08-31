import Foundation
@preconcurrency import Network

enum StreamTransportBridgeError: LocalizedError, Sendable {
    case invalidSource
    case listenerFailed(String)
    case malformedRequest
    case sourceNotFound
    case unsupportedRange
    case upstreamRejected(Int)
    case upstreamRangeMismatch
    case emptyUpstreamResponse

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            "The stream cannot be normalized because its size or byte-range support is unknown."
        case let .listenerFailed(message):
            "The local stream bridge could not start: \(message)"
        case .malformedRequest:
            "The player sent an invalid stream request."
        case .sourceNotFound:
            "The local stream session has expired."
        case .unsupportedRange:
            "The player requested an unsupported byte range."
        case let .upstreamRejected(status):
            "The stream provider rejected a byte request (HTTP \(status))."
        case .upstreamRangeMismatch:
            "The stream provider returned the wrong byte range."
        case .emptyUpstreamResponse:
            "The stream provider returned no media data."
        }
    }
}

/// Presents a provider file through a loopback-only HTTP byte-range endpoint.
///
/// Some debrid CDNs return raw MPEG-TS bytes from a URL named `.mp4`. The
/// relabeled remote delivery can produce unstable demux clocks and aggressive
/// frame dropping. This bridge keeps the original bytes intact while giving
/// Bunny a stable `.ts` identity, bounded reads, range validation, and a small
/// seek-aware cache.
actor StreamTransportBridge {
    static let shared = StreamTransportBridge()

    // The provider's H.264 transport stream uses a two-second keyframe
    // interval. Starting an exact byte seek at the requested PCR can leave the
    // video decoder without an IDR frame while audio immediately advances.
    // Resolve a little earlier so the playback path can discard decoded
    // preroll frames; this keeps the tracks synchronized without a visible
    // rewind.
    private static let vodSeekPrerollSeconds: TimeInterval = 3

    private struct Source: Sendable {
        let contentLength: Int64
        let mimeType: String
        let hlsManifest: Data
        let store: StreamChunkStore
        let registeredAt: ContinuousClock.Instant
    }

    private enum SourceResource: Sendable {
        case hlsManifest
        case media
    }

    private struct SourcePath: Sendable {
        let token: String
        let resource: SourceResource
    }

    private struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private struct ResponseRange: Sendable {
        let lowerBound: Int64
        let upperBound: Int64
        let isPartial: Bool

        var length: Int64 { upperBound - lowerBound + 1 }
    }

    private struct DeliveryPacer {
        let burstBytes: Int
        let bytesPerSecond: Double
        private var totalBytes = 0
        private var pacedBytes = 0
        private var pacingStartedAt: TimeInterval?

        init(
            bitrateBPS: UInt64,
            multiplier: Double,
            burstBytes: Int
        ) {
            let deliveryBitrate = min(
                max(Double(bitrateBPS) * multiplier, 1_500_000),
                100_000_000
            )
            self.burstBytes = burstBytes
            bytesPerSecond = deliveryBitrate / 8
        }

        mutating func waitBeforeSending(byteCount: Int) async throws {
            guard totalBytes >= burstBytes else {
                totalBytes += byteCount
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let startedAt = pacingStartedAt ?? now
            pacingStartedAt = startedAt
            let expectedElapsed = Double(pacedBytes) / bytesPerSecond
            let actualElapsed = now - startedAt
            if expectedElapsed > actualElapsed {
                try await Task.sleep(
                    for: .seconds(expectedElapsed - actualElapsed)
                )
            }
            pacedBytes += byteCount
            totalBytes += byteCount
        }
    }

    private let listenerQueue = DispatchQueue(
        label: "local.stremio.stream-transport-bridge",
        qos: .userInitiated
    )
    private var listener: NWListener?
    private var readyPort: UInt16?
    private var readinessWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var sources: [String: Source] = [:]

    func localURL(
        upstream: URL,
        contentLength: Int64,
        mimeType: String
    ) async throws -> URL {
        guard ["http", "https"].contains(upstream.scheme?.lowercased() ?? ""),
              contentLength > 0,
              mimeType == "video/mp2t"
        else {
            throw StreamTransportBridgeError.invalidSource
        }

        let token = UUID().uuidString.lowercased()
        let store = StreamChunkStore(
            upstream: upstream,
            contentLength: contentLength
        )
        let hlsManifest = try await store.hlsManifest()
        let port = try await startListenerIfNeeded()
        sources[token] = Source(
            contentLength: contentLength,
            mimeType: mimeType,
            hlsManifest: hlsManifest,
            store: store,
            registeredAt: .now
        )
        // Prune after insertion so the newly registered source is included in
        // the cap. Pruning beforehand allowed a thirteenth 64-MiB store to
        // remain resident until another stream happened to be registered.
        pruneExpiredSources()

        guard let url = URL(
            string: "http://127.0.0.1:\(port)/stream/\(token)/master.m3u8"
        ) else {
            throw StreamTransportBridgeError.invalidSource
        }
        #if DEBUG
        NSLog(
            "STREAM_BRIDGE_READY bytes=%lld mime=%@ port=%u",
            contentLength,
            mimeType,
            port
        )
        #endif
        return url
    }

    func unregister(localURL: URL) async {
        guard let token = Self.sourceToken(from: localURL.path),
              let source = sources.removeValue(forKey: token)
        else { return }
        await source.store.shutdown()
    }

    func releaseCachedData() async {
        for source in sources.values {
            await source.store.releaseCachedData()
        }
    }

    func resolvedByteOffset(
        for localURL: URL,
        time: TimeInterval,
        duration: TimeInterval
    ) async -> Int64? {
        guard duration.isFinite, duration > 0,
              time.isFinite,
              let token = Self.sourceToken(from: localURL.path),
              let source = sources[token]
        else { return nil }

        let indexedTime = max(time - Self.vodSeekPrerollSeconds, 0)
        let fraction = min(max(indexedTime / duration, 0), 1)
        let maximumOffset = source.contentLength - 1
        let virtualOffset = Int64(
            exactly: (Double(maximumOffset) * fraction).rounded()
        ) ?? maximumOffset
        do {
            let resolved = try await source.store.correctedUpstreamOffset(
                forVirtualOffset: virtualOffset
            )
            #if DEBUG
            NSLog(
                "STREAM_BRIDGE_SEEK_RESOLVED time=%.3f preroll_time=%.3f byte=%lld",
                time,
                indexedTime,
                resolved
            )
            #endif
            return resolved
        } catch {
            NSLog(
                "STREAM_BRIDGE_SEEK_RESOLVE_FAILED error=%@",
                error.localizedDescription
            )
            return nil
        }
    }

    private func startListenerIfNeeded() async throws -> UInt16 {
        if let readyPort { return readyPort }
        if listener != nil {
            return try await withCheckedThrowingContinuation { continuation in
                readinessWaiters.append(continuation)
            }
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: .any)
        } catch {
            throw StreamTransportBridgeError.listenerFailed(
                error.localizedDescription
            )
        }
        listener = newListener

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                guard let port = newListener?.port?.rawValue else {
                    Task {
                        await self?.listenerFailed("No loopback port was assigned.")
                    }
                    return
                }
                Task { await self?.listenerBecameReady(port: port) }
            case let .failed(error):
                Task { await self?.listenerFailed(error.localizedDescription) }
            case .cancelled:
                Task { await self?.listenerCancelled() }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.listenerQueue ?? .global(qos: .userInitiated))
            Task { await self?.serve(connection) }
        }
        newListener.start(queue: listenerQueue)

        return try await withCheckedThrowingContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    private func listenerBecameReady(port: UInt16) {
        readyPort = port
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        waiters.forEach { $0.resume(returning: port) }
    }

    private func listenerFailed(_ message: String) {
        readyPort = nil
        listener?.cancel()
        listener = nil
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        waiters.forEach {
            $0.resume(
                throwing: StreamTransportBridgeError.listenerFailed(message)
            )
        }
        NSLog("STREAM_BRIDGE_LISTENER_FAILED error=%@", message)
    }

    private func listenerCancelled() {
        guard listener != nil else { return }
        listenerFailed("The loopback listener was cancelled.")
    }

    private func pruneExpiredSources() {
        let expiration = Duration.seconds(6 * 60 * 60)
        let expiredTokens = sources.compactMap { token, source in
            source.registeredAt.duration(to: .now) >= expiration ? token : nil
        }
        for token in expiredTokens {
            removeSource(token)
        }
        if sources.count > 4 {
            let oldest = sources.sorted {
                $0.value.registeredAt < $1.value.registeredAt
            }
            for (token, _) in oldest.prefix(sources.count - 4) {
                removeSource(token)
            }
        }
    }

    private func removeSource(_ token: String) {
        guard let source = sources.removeValue(forKey: token) else { return }
        Task { await source.store.shutdown() }
    }

    private func serve(_ connection: NWConnection) async {
        do {
            let requestData = try await Self.receiveRequestHeader(from: connection)
            let request = try Self.parseRequest(requestData)
            guard let sourcePath = Self.sourcePath(from: request.path),
                  let source = sources[sourcePath.token]
            else {
                try await Self.sendError(
                    status: 404,
                    reason: "Not Found",
                    over: connection
                )
                return
            }
            switch sourcePath.resource {
            case .hlsManifest:
                try await Self.respondWithManifest(
                    to: request,
                    source: source,
                    over: connection
                )
            case .media:
                try await Self.respondWithMedia(
                    to: request,
                    source: source,
                    over: connection
                )
            }
        } catch {
            NSLog(
                "STREAM_BRIDGE_REQUEST_FAILED error=%@",
                error.localizedDescription
            )
            connection.cancel()
        }
    }

    private nonisolated static func receiveRequestHeader(
        from connection: NWConnection
    ) async throws -> Data {
        let marker = Data("\r\n\r\n".utf8)
        var result = Data()
        while result.range(of: marker) == nil {
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else {
                throw StreamTransportBridgeError.malformedRequest
            }
            result.append(chunk)
            guard result.count <= 65_536 else {
                throw StreamTransportBridgeError.malformedRequest
            }
        }
        return result
    }

    private nonisolated static func receive(
        from connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 16_384
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(
                        throwing: StreamTransportBridgeError.malformedRequest
                    )
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private nonisolated static func parseRequest(_ data: Data) throws -> Request {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(
                  data: data[..<headerEnd.lowerBound],
                  encoding: .utf8
              )
        else {
            throw StreamTransportBridgeError.malformedRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw StreamTransportBridgeError.malformedRequest
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            throw StreamTransportBridgeError.malformedRequest
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            throw StreamTransportBridgeError.malformedRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return Request(method: method, path: String(parts[1]), headers: headers)
    }

    private nonisolated static func sourceToken(from path: String) -> String? {
        sourcePath(from: path)?.token
    }

    private nonisolated static func sourcePath(from path: String) -> SourcePath? {
        let cleanPath = path.split(separator: "?", maxSplits: 1).first ?? ""
        let components = cleanPath.split(separator: "/")
        guard components.count == 3, components[0] == "stream" else { return nil }
        let resource: SourceResource
        switch components[2] {
        case "master.m3u8": resource = .hlsManifest
        case "media.ts": resource = .media
        default: return nil
        }
        return SourcePath(token: String(components[1]), resource: resource)
    }

    private nonisolated static func responseRange(
        header: String?,
        contentLength: Int64
    ) throws -> ResponseRange {
        guard let header, !header.isEmpty else {
            return ResponseRange(
                lowerBound: 0,
                upperBound: contentLength - 1,
                isPartial: false
            )
        }
        let normalized = header.lowercased()
        guard normalized.hasPrefix("bytes="),
              !normalized.contains(",")
        else {
            throw StreamTransportBridgeError.unsupportedRange
        }
        let value = normalized.dropFirst("bytes=".count)
        let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else {
            throw StreamTransportBridgeError.unsupportedRange
        }

        let lower: Int64
        let upper: Int64
        if bounds[0].isEmpty {
            guard let suffixLength = Int64(bounds[1]), suffixLength > 0 else {
                throw StreamTransportBridgeError.unsupportedRange
            }
            lower = max(0, contentLength - suffixLength)
            upper = contentLength - 1
        } else {
            guard let parsedLower = Int64(bounds[0]), parsedLower >= 0 else {
                throw StreamTransportBridgeError.unsupportedRange
            }
            lower = parsedLower
            if bounds[1].isEmpty {
                upper = contentLength - 1
            } else {
                guard let parsedUpper = Int64(bounds[1]), parsedUpper >= lower else {
                    throw StreamTransportBridgeError.unsupportedRange
                }
                upper = min(parsedUpper, contentLength - 1)
            }
        }
        guard lower < contentLength else {
            throw StreamTransportBridgeError.unsupportedRange
        }
        return ResponseRange(
            lowerBound: lower,
            upperBound: upper,
            isPartial: true
        )
    }

    private nonisolated static func respondWithManifest(
        to request: Request,
        source: Source,
        over connection: NWConnection
    ) async throws {
        let contentLength = Int64(source.hlsManifest.count)
        let range: ResponseRange
        do {
            range = try responseRange(
                header: request.headers["range"],
                contentLength: contentLength
            )
        } catch {
            try await sendError(
                status: 416,
                reason: "Range Not Satisfiable",
                extraHeaders: ["Content-Range: bytes */\(contentLength)"],
                over: connection
            )
            return
        }

        let status = range.isPartial ? "206 Partial Content" : "200 OK"
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/vnd.apple.mpegurl",
            "Content-Length: \(range.length)",
            "Accept-Ranges: bytes",
            "Cache-Control: no-store",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
        ]
        if range.isPartial {
            headers.append(
                "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(contentLength)"
            )
        }
        let isHead = request.method == "HEAD"
        let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        try await send(headerData, isComplete: isHead, over: connection)
        if !isHead {
            let lower = Int(range.lowerBound)
            let upper = Int(range.upperBound) + 1
            try await send(
                source.hlsManifest.subdata(in: lower..<upper),
                isComplete: true,
                over: connection
            )
        }
        connection.cancel()
    }

    private nonisolated static func respondWithMedia(
        to request: Request,
        source: Source,
        over connection: NWConnection
    ) async throws {
        let range: ResponseRange
        do {
            range = try responseRange(
                header: request.headers["range"],
                contentLength: source.contentLength
            )
        } catch {
            try await sendError(
                status: 416,
                reason: "Range Not Satisfiable",
                extraHeaders: ["Content-Range: bytes */\(source.contentLength)"],
                over: connection
            )
            return
        }

        let isTailProbe = range.upperBound == source.contentLength - 1
            && range.length <= 512 * 1_024
        let isHead = request.method == "HEAD"
        // Preserve a one-to-one HTTP byte coordinate. Replacing bytes behind
        // an advertised offset would corrupt the next relative seek.
        let upstreamStart = range.lowerBound

        let status = range.isPartial ? "206 Partial Content" : "200 OK"
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(source.mimeType)",
            "Content-Length: \(range.length)",
            "Accept-Ranges: bytes",
            "Cache-Control: no-store",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
        ]
        if range.isPartial {
            headers.append(
                "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(source.contentLength)"
            )
        }
        let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        try await send(headerData, isComplete: isHead, over: connection)
        if isHead {
            connection.cancel()
            return
        }

        #if DEBUG
        NSLog(
            "STREAM_BRIDGE_REQUEST start=%lld upstream_start=%lld end=%lld partial=%@",
            range.lowerBound,
            upstreamStart,
            range.upperBound,
            range.isPartial ? "true" : "false"
        )
        #endif
        var virtualOffset = range.lowerBound
        var upstreamOffset = upstreamStart
        var pacer: DeliveryPacer?
        while virtualOffset <= range.upperBound,
              upstreamOffset < source.contentLength {
            try Task.checkCancellation()
            let virtualRemaining = range.upperBound - virtualOffset + 1
            let upstreamRemaining = source.contentLength - upstreamOffset
            let maximumCount = Int(
                min(virtualRemaining, upstreamRemaining, 2 * 1_024 * 1_024)
            )
            let data = try await source.store.bytes(
                at: upstreamOffset,
                maximumCount: maximumCount
            )
            guard !data.isEmpty else {
                throw StreamTransportBridgeError.emptyUpstreamResponse
            }
            if pacer == nil {
                let estimatedBitrate = await source.store.pacingBitrateBPS()
                    ?? 12_000_000
                let startsAtBeginning = range.lowerBound == 0
                let burstBytes: Int
                let multiplier: Double
                if isTailProbe {
                    burstBytes = Int.max
                    multiplier = 1
                } else if startsAtBeginning {
                    burstBytes = 4 * 1_024 * 1_024
                    multiplier = 2.5
                } else {
                    // A seek needs enough compressed media immediately to
                    // refill both decoder queues. Four MiB is roughly twelve
                    // seconds of this stream, matching the bounded decoded
                    // queue while avoiding the post-seek starvation measured
                    // with a two-MiB burst.
                    burstBytes = 4 * 1_024 * 1_024
                    multiplier = 2.5
                }
                pacer = DeliveryPacer(
                    bitrateBPS: estimatedBitrate,
                    multiplier: multiplier,
                    burstBytes: burstBytes
                )
                #if DEBUG
                NSLog(
                    "STREAM_BRIDGE_PACING source_bps=%llu multiplier=%.2f burst_bytes=%ld",
                    estimatedBitrate,
                    multiplier,
                    burstBytes
                )
                #endif
            }

            var dataOffset = 0
            while dataOffset < data.count {
                let segmentCount = min(64 * 1_024, data.count - dataOffset)
                if var activePacer = pacer {
                    try await activePacer.waitBeforeSending(
                        byteCount: segmentCount
                    )
                    pacer = activePacer
                }
                let segment = data.subdata(
                    in: dataOffset..<(dataOffset + segmentCount)
                )
                let nextVirtualOffset = virtualOffset
                    + Int64(dataOffset + segmentCount)
                let nextUpstreamOffset = upstreamOffset
                    + Int64(dataOffset + segmentCount)
                let isComplete = nextVirtualOffset > range.upperBound
                    || nextUpstreamOffset >= source.contentLength
                try await send(
                    segment,
                    isComplete: isComplete,
                    over: connection
                )
                dataOffset += segmentCount
            }
            virtualOffset += Int64(data.count)
            upstreamOffset += Int64(data.count)
        }
        connection.cancel()
    }

    private nonisolated static func sendError(
        status: Int,
        reason: String,
        extraHeaders: [String] = [],
        over connection: NWConnection
    ) async throws {
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Length: 0",
            "Connection: close",
        ] + extraHeaders
        try await send(
            Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8),
            isComplete: true,
            over: connection
        )
        connection.cancel()
    }

    private nonisolated static func send(
        _ data: Data,
        isComplete: Bool,
        over connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }
}

private actor StreamChunkStore {
    private struct CachedChunk: Sendable {
        let data: Data
        var lastAccess: UInt64
    }

    private struct PCRSpan: Sendable {
        let pcrPID: UInt16
        let firstPCRTicks: UInt64
        let lastPCRTicks: UInt64
        let firstByteOffset: Int64
        let lastByteOffset: Int64
        let bitrateBPS: UInt64
    }

    private struct PCRPoint: Sendable {
        let byteOffset: Int64
        let ticks: UInt64
    }

    private struct PCRLookup: Sendable {
        let elapsedTicks: Double
        let localBitrateBPS: UInt64
    }

    // Timestamp seeking opens several short-lived range probes. A two-MiB
    // fetch made every probe pay for data the demuxer immediately discarded.
    // Half-MiB chunks still span enough PCR samples for bitrate estimation,
    // while cutting cold seek transfer and latency substantially.
    private static let chunkSize: Int64 = 512 * 1_024
    // Four retained bridge sources at 16 MiB each impose a 64 MiB global
    // ceiling. Playback teardown unregisters its source, while this bounded
    // fallback also protects interrupted setup and abandoned navigation.
    private static let maximumCachedBytes = 16 * 1_024 * 1_024
    private static let pcrTimescale = 27_000_000.0
    private static let pcrWrap = (UInt64(1) << 33) * 300

    private let upstream: URL
    private let contentLength: Int64
    private let session: URLSession
    private var cache: [Int64: CachedChunk] = [:]
    private var inFlight: [Int64: Task<Data, Error>] = [:]
    private var cachedBytes = 0
    private var accessCounter: UInt64 = 0
    private var estimatedBitrateBPS: UInt64?
    private var timingSpans: [Int64: PCRSpan] = [:]

    init(upstream: URL, contentLength: Int64) {
        self.upstream = upstream
        self.contentLength = contentLength
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    func releaseCachedData() {
        cache.removeAll(keepingCapacity: false)
        timingSpans.removeAll(keepingCapacity: false)
        cachedBytes = 0
    }

    func shutdown() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll(keepingCapacity: false)
        releaseCachedData()
        session.invalidateAndCancel()
    }

    func bytes(at offset: Int64, maximumCount: Int) async throws -> Data {
        guard offset >= 0, offset < contentLength, maximumCount > 0 else {
            throw StreamTransportBridgeError.unsupportedRange
        }
        let chunkOffset = (offset / Self.chunkSize) * Self.chunkSize
        let chunk = try await chunk(startingAt: chunkOffset)
        let localOffset = Int(offset - chunkOffset)
        guard localOffset < chunk.count else {
            throw StreamTransportBridgeError.upstreamRangeMismatch
        }
        let count = min(maximumCount, chunk.count - localOffset)
        return chunk.subdata(in: localOffset..<(localOffset + count))
    }

    func pacingBitrateBPS() -> UInt64? {
        estimatedBitrateBPS
    }

    func hlsManifest() async throws -> Data {
        _ = try await chunk(startingAt: 0)
        let tailOffset = ((contentLength - 1) / Self.chunkSize) * Self.chunkSize
        if tailOffset > 0 {
            _ = try await chunk(startingAt: tailOffset)
        }

        let duration: TimeInterval
        if let timeline = timelineEndpoints() {
            let ticks = Self.pcrDelta(
                from: timeline.first.ticks,
                to: timeline.last.ticks
            )
            duration = Double(ticks) / Self.pcrTimescale
        } else {
            let bitrate = max(estimatedBitrateBPS ?? 12_000_000, 1)
            duration = Double(contentLength) * 8 / Double(bitrate)
        }
        guard duration.isFinite, duration > 0 else {
            throw StreamTransportBridgeError.invalidSource
        }
        let layout: MPEGTransportHLSManifest
        do {
            layout = try MPEGTransportHLSManifest.build(
                contentLength: contentLength,
                duration: duration
            )
        } catch {
            throw StreamTransportBridgeError.invalidSource
        }
        let manifest = layout.encoded()
        #if DEBUG
        NSLog(
            "STREAM_BRIDGE_HLS duration=%.3f segments=%lld segment_bytes=%lld manifest_bytes=%ld",
            duration,
            Int64(layout.segments.count),
            layout.segmentByteLength,
            manifest.count
        )
        #endif
        return manifest
    }

    func correctedUpstreamOffset(
        forVirtualOffset virtualOffset: Int64
    ) async throws -> Int64 {
        guard virtualOffset > 0, virtualOffset < contentLength else {
            return virtualOffset
        }

        _ = try await chunk(startingAt: 0)
        let tailOffset = ((contentLength - 1) / Self.chunkSize) * Self.chunkSize
        _ = try await chunk(startingAt: tailOffset)
        _ = try await chunk(
            startingAt: (virtualOffset / Self.chunkSize) * Self.chunkSize
        )

        guard let timeline = timelineEndpoints() else {
            return virtualOffset
        }
        let totalTicks = Self.pcrDelta(
            from: timeline.first.ticks,
            to: timeline.last.ticks
        )
        guard totalTicks > 0 else { return virtualOffset }
        let virtualFraction = min(
            max(Double(virtualOffset) / Double(contentLength - 1), 0),
            1
        )
        let targetElapsedTicks = Double(totalTicks) * virtualFraction

        var candidate = virtualOffset
        var residualMilliseconds = Double.infinity
        for _ in 0..<8 {
            _ = try await chunk(
                startingAt: (candidate / Self.chunkSize) * Self.chunkSize
            )
            guard let lookup = pcrLookup(
                at: candidate,
                pcrPID: timeline.pcrPID,
                originTicks: timeline.first.ticks
            ) else {
                break
            }
            let timingErrorSeconds = (
                lookup.elapsedTicks - targetElapsedTicks
            ) / Self.pcrTimescale
            residualMilliseconds = timingErrorSeconds * 1_000
            if abs(timingErrorSeconds) < 0.20 { break }

            // MPEG-TS VOD can be strongly variable bitrate. Using the exact
            // nearby PCR slope makes this a true local Newton correction;
            // the smoothed whole-file rate oscillated by several seconds.
            let bitrate = Double(lookup.localBitrateBPS)
            let maximumCorrection = min(contentLength / 8, 512 * 1_024 * 1_024)
            let estimatedCorrection = timingErrorSeconds * bitrate / 8
            var byteCorrection: Int64
            if estimatedCorrection >= Double(maximumCorrection) {
                byteCorrection = maximumCorrection
            } else if estimatedCorrection <= Double(-maximumCorrection) {
                byteCorrection = -maximumCorrection
            } else {
                byteCorrection = Int64(exactly: estimatedCorrection.rounded()) ?? 0
            }
            byteCorrection = (byteCorrection / 188) * 188
            let maximumOffset = contentLength - 1
            let corrected: Int64
            if byteCorrection >= 0 {
                corrected = byteCorrection >= candidate
                    ? 0
                    : candidate - byteCorrection
            } else {
                // `byteCorrection` is bounded to 512 MiB above, so negating it
                // is safe. Compare against the remaining distance before
                // adding: clamping an already-overflowed value is too late for
                // streams whose declared size approaches Int64.max.
                let increase = -byteCorrection
                let remaining = maximumOffset - candidate
                corrected = increase >= remaining
                    ? maximumOffset
                    : candidate + increase
            }
            guard corrected != candidate else { break }
            candidate = corrected
        }

        #if DEBUG
        if candidate != virtualOffset {
            NSLog(
                "STREAM_BRIDGE_SEEK_MAP virtual=%lld upstream=%lld correction_bytes=%lld residual_ms=%.1f",
                virtualOffset,
                candidate,
                virtualOffset - candidate,
                residualMilliseconds
            )
        }
        #endif
        return candidate
    }

    private func chunk(startingAt offset: Int64) async throws -> Data {
        accessCounter &+= 1
        if var cached = cache[offset] {
            cached.lastAccess = accessCounter
            cache[offset] = cached
            return cached.data
        }

        let task: Task<Data, Error>
        if let existing = inFlight[offset] {
            task = existing
        } else {
            let upstream = upstream
            let contentLength = contentLength
            let session = session
            task = Task {
                try await Self.downloadChunk(
                    from: upstream,
                    contentLength: contentLength,
                    offset: offset,
                    session: session
                )
            }
            inFlight[offset] = task
        }

        do {
            let data = try await task.value
            inFlight[offset] = nil
            if cache[offset] == nil {
                insert(data, at: offset)
            }
            return data
        } catch {
            inFlight[offset] = nil
            throw error
        }
    }

    private func insert(_ data: Data, at offset: Int64) {
        accessCounter &+= 1
        cache[offset] = CachedChunk(data: data, lastAccess: accessCounter)
        cachedBytes += data.count
        if let timing = PlaybackPerformanceCore.mpegTransportTiming(in: data),
           timing.firstByteOffset <= timing.lastByteOffset,
           timing.lastByteOffset < UInt64(data.count),
           let relativeFirst = Int64(exactly: timing.firstByteOffset),
           let relativeLast = Int64(exactly: timing.lastByteOffset)
        {
            let (firstByteOffset, firstOverflow) = offset.addingReportingOverflow(
                relativeFirst
            )
            let (lastByteOffset, lastOverflow) = offset.addingReportingOverflow(
                relativeLast
            )
            guard !firstOverflow, !lastOverflow,
                  firstByteOffset >= 0,
                  lastByteOffset < contentLength
            else {
                evictExcessCachedData()
                return
            }
            let span = PCRSpan(
                pcrPID: timing.pcrPID,
                firstPCRTicks: timing.firstPCRTicks,
                lastPCRTicks: timing.lastPCRTicks,
                firstByteOffset: firstByteOffset,
                lastByteOffset: lastByteOffset,
                bitrateBPS: timing.bitrateBPS
            )
            timingSpans[offset] = span
            let measured = timing.bitrateBPS
            if let current = estimatedBitrateBPS {
                estimatedBitrateBPS = (current * 3 + measured) / 4
            } else {
                estimatedBitrateBPS = measured
                #if DEBUG
                NSLog("STREAM_BRIDGE_PROBE bitrate_bps=%llu", measured)
                #endif
            }
        }
        evictExcessCachedData()
    }

    private func evictExcessCachedData() {
        while cachedBytes > Self.maximumCachedBytes,
              let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })
        {
            cache[oldest.key] = nil
            cachedBytes -= oldest.value.data.count
        }
    }

    private func timelineEndpoints() -> (
        pcrPID: UInt16,
        first: PCRPoint,
        last: PCRPoint
    )? {
        let grouped = Dictionary(grouping: timingSpans.values, by: \PCRSpan.pcrPID)
        return grouped.compactMap { pcrPID, spans in
            guard let firstSpan = spans.min(by: {
                $0.firstByteOffset < $1.firstByteOffset
            }),
            let lastSpan = spans.max(by: {
                $0.lastByteOffset < $1.lastByteOffset
            }),
            firstSpan.firstByteOffset <= 4 * 1_024 * 1_024,
            lastSpan.lastByteOffset >= contentLength - 4 * 1_024 * 1_024
            else { return nil }
            let first = PCRPoint(
                byteOffset: firstSpan.firstByteOffset,
                ticks: firstSpan.firstPCRTicks
            )
            let last = PCRPoint(
                byteOffset: lastSpan.lastByteOffset,
                ticks: lastSpan.lastPCRTicks
            )
            return (pcrPID, first, last)
        }.max {
            ($0.last.byteOffset - $0.first.byteOffset)
                < ($1.last.byteOffset - $1.first.byteOffset)
        }
    }

    private func pcrLookup(
        at byteOffset: Int64,
        pcrPID: UInt16,
        originTicks: UInt64
    ) -> PCRLookup? {
        let spans = timingSpans.values.filter { $0.pcrPID == pcrPID }
        guard let span = spans.min(by: {
            Self.distance(from: byteOffset, to: $0)
                < Self.distance(from: byteOffset, to: $1)
        }) else { return nil }
        let byteSpan = max(span.lastByteOffset - span.firstByteOffset, 1)
        let fraction = min(
            max(
                Double(byteOffset - span.firstByteOffset) / Double(byteSpan),
                0
            ),
            1
        )
        let spanTicks = Self.pcrDelta(
            from: span.firstPCRTicks,
            to: span.lastPCRTicks
        )
        let interpolatedOffset = UInt64(
            (Double(spanTicks) * fraction).rounded()
        )
        let interpolatedTicks = (span.firstPCRTicks + interpolatedOffset)
            % Self.pcrWrap
        return PCRLookup(
            elapsedTicks: Double(
                Self.pcrDelta(from: originTicks, to: interpolatedTicks)
            ),
            localBitrateBPS: span.bitrateBPS
        )
    }

    private nonisolated static func pcrDelta(
        from first: UInt64,
        to last: UInt64
    ) -> UInt64 {
        last >= first ? last - first : pcrWrap - first + last
    }

    private nonisolated static func distance(
        from byteOffset: Int64,
        to span: PCRSpan
    ) -> Int64 {
        if byteOffset < span.firstByteOffset {
            return span.firstByteOffset - byteOffset
        }
        if byteOffset > span.lastByteOffset {
            return byteOffset - span.lastByteOffset
        }
        return 0
    }

    private nonisolated static func downloadChunk(
        from upstream: URL,
        contentLength: Int64,
        offset: Int64,
        session: URLSession
    ) async throws -> Data {
        guard contentLength > 0, offset >= 0, offset < contentLength else {
            throw StreamTransportBridgeError.unsupportedRange
        }
        let remaining = contentLength - offset
        let requestedCount = min(chunkSize, remaining)
        guard requestedCount > 0,
              let expectedCount = Int(exactly: requestedCount)
        else {
            throw StreamTransportBridgeError.unsupportedRange
        }
        // `requestedCount <= contentLength - offset`, so this addition cannot
        // exceed the validated positive content length even at Int64.max.
        let upperBound = offset + requestedCount - 1
        var lastError: Error?

        for attempt in 1...3 {
            #if DEBUG
            let startedAt = ContinuousClock.now
            #endif
            do {
                var request = URLRequest(url: upstream)
                request.timeoutInterval = 12
                request.setValue(
                    "bytes=\(offset)-\(upperBound)",
                    forHTTPHeaderField: "Range"
                )
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await BoundedHTTPDataLoader.load(
                        request: request,
                        maximumBytes: expectedCount,
                        configuration: session.configuration,
                        redirectPolicy: .follow,
                        preserveHeadersAcrossRedirects: ["Range", "Accept-Encoding"]
                    )
                } catch BoundedHTTPDataLoaderError.responseTooLarge {
                    throw StreamTransportBridgeError.upstreamRangeMismatch
                }
                guard let http = response as? HTTPURLResponse else {
                    throw StreamTransportBridgeError.upstreamRangeMismatch
                }
                guard http.statusCode == 206 else {
                    throw StreamTransportBridgeError.upstreamRejected(http.statusCode)
                }
                guard responseRangeStart(http) == offset,
                      data.count == expectedCount
                else {
                    throw StreamTransportBridgeError.upstreamRangeMismatch
                }

                #if DEBUG
                let elapsed = max(
                    startedAt.duration(to: .now).components.seconds,
                    0
                )
                let milliseconds = Double(elapsed) * 1_000
                    + Double(startedAt.duration(to: .now).components.attoseconds)
                        / 1_000_000_000_000_000
                let megabitsPerSecond = milliseconds > 0
                    ? Double(data.count) * 8 / milliseconds / 1_000
                    : 0
                NSLog(
                    "STREAM_BRIDGE_FETCH offset=%lld bytes=%ld ms=%.1f mbps=%.1f attempt=%ld",
                    offset,
                    data.count,
                    milliseconds,
                    megabitsPerSecond,
                    attempt
                )
                #endif
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < 3, isRetryable(error) else { throw error }
                NSLog(
                    "STREAM_BRIDGE_FETCH_RETRY offset=%lld attempt=%ld error=%@",
                    offset,
                    attempt,
                    error.localizedDescription
                )
                try await Task.sleep(for: .milliseconds(200 * attempt))
            }
        }
        throw lastError ?? StreamTransportBridgeError.emptyUpstreamResponse
    }

    private nonisolated static func responseRangeStart(
        _ response: HTTPURLResponse
    ) -> Int64? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range")?
            .lowercased(),
              header.hasPrefix("bytes ")
        else { return nil }
        let rangeAndTotal = header.dropFirst("bytes ".count)
            .split(separator: "/", maxSplits: 1)
        guard let range = rangeAndTotal.first else { return nil }
        guard let start = range.split(separator: "-", maxSplits: 1).first else {
            return nil
        }
        return Int64(String(start))
    }

    private nonisolated static func isRetryable(_ error: Error) -> Bool {
        if let bridgeError = error as? StreamTransportBridgeError {
            return switch bridgeError {
            case let .upstreamRejected(status):
                status == 408 || status == 429 || (500...599).contains(status)
            default:
                false
            }
        }
        guard let urlError = error as? URLError else { return false }
        return switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable:
            true
        default:
            false
        }
    }
}
