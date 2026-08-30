import Darwin
import Foundation

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
    private var received = PlaybackReceiveBuffer()
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
            received.reset()
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
        if let failure {
            received.discard()
            activeOperationID = nil
            throw failure
        }
        guard let response else {
            received.discard()
            activeOperationID = nil
            throw BunnyNativeDecoderError.network("missing HTTP response")
        }
        activeOperationID = nil
        return Result(data: received.take(), response: response)
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
              maximumLength > 0
        else { return nil }
        return received.copy(
            relativeOffset: relativeOffset,
            to: output,
            maximumLength: maximumLength
        )
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
        received.append(data, maximumCount: maximumBytes)
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
            received.discard()
        }
        let progress = progressSemaphore
        lock.unlock()
        progress.signal()
        semaphore.signal()
    }
}

final class BunnyMediaRangeReader: @unchecked Sendable {
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

    /// Drops speculative and least-recently-used remote data without closing
    /// the source or invalidating the most recently consumed chunk. This is
    /// safe to request from a memory-warning callback while a foreground read
    /// is active; cancellation wakes prefetch waiters and the cache mutation
    /// waits on the reader lock off the main actor.
    func trimForMemoryPressure() {
        cancelPrefetch()
        let releasedBytes = lock.withLock { () -> Int in
            guard chunks.count > 1 else { return 0 }
            let released = chunks.dropFirst().reduce(0) { $0 + $1.data.count }
            chunks.removeSubrange(1...)
            return released
        }
        NSLog(
            "BUNNY_RANGE_MEMORY_PRESSURE released_bytes=%ld retained_chunks=%ld",
            releasedBytes,
            lock.withLock { chunks.count }
        )
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

let bunnyNativeReadAt: @convention(c) (
    UnsafeMutableRawPointer?,
    UInt64,
    UnsafeMutablePointer<UInt8>?,
    Int
) -> Int64 = { context, offset, output, length in
    guard let context, let output else { return -1 }
    let reader = Unmanaged<BunnyMediaRangeReader>.fromOpaque(context).takeUnretainedValue()
    return reader.read(offset: offset, output: output, length: length)
}
