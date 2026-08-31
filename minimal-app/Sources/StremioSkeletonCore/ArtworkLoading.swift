import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ArtworkResourceLimits: Hashable, Sendable {
    public let maximumEncodedBytes: Int
    public let maximumDecodedPixels: Int64
    public let maximumDimension: Int64
    public let maximumFrameCount: Int
    public let maximumCacheEntries: Int
    public let maximumCacheBytes: Int
    public let maximumConcurrentRequests: Int
    public let maximumWaitersPerRequest: Int

    public init(
        maximumEncodedBytes: Int,
        maximumDecodedPixels: Int64,
        maximumDimension: Int64,
        maximumFrameCount: Int,
        maximumCacheEntries: Int,
        maximumCacheBytes: Int,
        maximumConcurrentRequests: Int = 8,
        maximumWaitersPerRequest: Int = 16
    ) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedPixels = maximumDecodedPixels
        self.maximumDimension = maximumDimension
        self.maximumFrameCount = maximumFrameCount
        self.maximumCacheEntries = maximumCacheEntries
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumWaitersPerRequest = maximumWaitersPerRequest
    }

    public static let mobile = ArtworkResourceLimits(
        maximumEncodedBytes: 12 * 1_024 * 1_024,
        maximumDecodedPixels: 12_000_000,
        maximumDimension: 8_192,
        maximumFrameCount: 60,
        maximumCacheEntries: 120,
        maximumCacheBytes: 64 * 1_024 * 1_024,
        maximumConcurrentRequests: 8,
        maximumWaitersPerRequest: 16
    )

    public static let television = ArtworkResourceLimits(
        maximumEncodedBytes: 12 * 1_024 * 1_024,
        maximumDecodedPixels: 16_000_000,
        maximumDimension: 8_192,
        maximumFrameCount: 60,
        maximumCacheEntries: 160,
        maximumCacheBytes: 96 * 1_024 * 1_024,
        maximumConcurrentRequests: 12,
        maximumWaitersPerRequest: 24
    )

    public static let watch = ArtworkResourceLimits(
        maximumEncodedBytes: 4 * 1_024 * 1_024,
        maximumDecodedPixels: 4_000_000,
        maximumDimension: 4_096,
        maximumFrameCount: 30,
        maximumCacheEntries: 48,
        maximumCacheBytes: 12 * 1_024 * 1_024,
        maximumConcurrentRequests: 4,
        maximumWaitersPerRequest: 8
    )
}

public enum ArtworkURLTrustPolicy {
    /// Artwork is untrusted provider metadata. Validate the first destination
    /// before URLSession is allowed to issue a request; redirect destinations
    /// remain guarded independently by BoundedHTTPDataLoader. Hostnames are
    /// HTTPS-only on port 443 so URLSession's ordinary server-trust evaluation
    /// remains between a DNS answer and an internal cleartext service. Public
    /// IP literals may use only their standard HTTP/HTTPS ports.
    ///
    /// URLSession does not expose a supported way to bind the connected peer
    /// address to this preflight resolution. Default HTTPS trust plus per-hop
    /// revalidation is therefore the boundary; no custom or permissive trust
    /// handler is installed here.
    public static func allowsInitialRequest(_ url: URL) -> Bool {
        allowsInitialRequest(
            url,
            resolvingWith: { resolvedAddresses(for: $0) }
        )
    }

    static func allowsInitialRequest(
        _ url: URL,
        resolvingWith resolver: (String) -> [[UInt8]]?
    ) -> Bool {
        guard url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty
        else { return false }

        let host = normalizedHost(rawHost)
        guard !host.isEmpty else { return false }
        if let literalAddress = addressBytes(forIPAddressLiteral: host) {
            guard usesStandardPort(url, scheme: scheme) else { return false }
            // Cleartext compatibility is intentionally limited to canonical
            // dotted-quad public IPv4. IPv6 (including any NAT64 form) keeps
            // default TLS trust as the DNS/connect boundary.
            if scheme == "http", literalAddress.count != 4 { return false }
            return !isRestrictedAddress(literalAddress)
        }

        guard scheme == "https",
              (url.port == nil || url.port == 443),
              !isLocalHostname(host),
              let addresses = resolver(host),
              !addresses.isEmpty,
              !addresses.contains(where: isRestrictedAddress)
        else { return false }
        return true
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func usesStandardPort(_ url: URL, scheme: String) -> Bool {
        switch scheme {
        case "http":
            return url.port == nil || url.port == 80
        case "https":
            return url.port == nil || url.port == 443
        default:
            return false
        }
    }

    private static func addressBytes(forIPAddressLiteral host: String) -> [UInt8]? {
        guard !host.contains("%") else { return nil }

        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4) { Array($0) }
        }

        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { Array($0) }
        }
        return nil
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".home.arpa")
    }

    private static func resolvedAddresses(for host: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return nil }
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
                || (first == 192 && second == 0)
                || (first == 192 && second == 168)
                || (first == 192 && second == 88 && bytes[2] == 99)
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
        // RFC 6052's well-known DNS64/NAT64 prefix has a fixed /96
        // embedding, so preserve IPv6-only access only when its IPv4 target
        // independently passes the same public-address policy.
        if bytes.prefix(12).elementsEqual([
            0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]) {
            return isRestrictedAddress(Array(bytes.suffix(4)))
        }
        // RFC 8215 explicitly makes 64:ff9b:1::/48 technology-agnostic and
        // forbids assuming where (or whether) an IPv4 address is embedded.
        // It is local-use, so it cannot prove a public destination here.
        if bytes.prefix(6).elementsEqual([0x00, 0x64, 0xff, 0x9b, 0x00, 0x01]) {
            return true
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            return isRestrictedAddress(Array(bytes.suffix(4)))
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isRestrictedAddress(Array(bytes.suffix(4)))
        }
        // Transition/documentation prefixes are not public artwork origins.
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return true }
        guard bytes[0] & 0xe0 == 0x20 else { return true }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] == 0x00 || bytes[2] == 0x02 || bytes[2] == 0x0d {
                return true
            }
        }
        if bytes[0] == 0x3f && bytes[1] == 0xfe { return true }
        if bytes[0] == 0x3f && (bytes[1] & 0xf0) == 0xf0 { return true }
        if bytes[0] == 0x5f { return true }
        return false
    }
}

enum ArtworkRedirectTrustPolicy {
    static func allows(from sourceURL: URL, to destinationURL: URL) -> Bool {
        BoundedHTTPRedirectTrustPolicy.allows(
            from: sourceURL,
            to: destinationURL
        ) && ArtworkURLTrustPolicy.allowsInitialRequest(destinationURL)
    }

    static func allows(
        from sourceURL: URL,
        to destinationURL: URL,
        resolvingWith resolver: (String) -> [[UInt8]]?
    ) -> Bool {
        BoundedHTTPRedirectTrustPolicy.allows(
            from: sourceURL,
            to: destinationURL
        ) && ArtworkURLTrustPolicy.allowsInitialRequest(
            destinationURL,
            resolvingWith: resolver
        )
    }
}

struct ArtworkDecodedFrame: Equatable, Sendable {
    let width: Int64
    let height: Int64
}

enum ArtworkResourcePolicy {
    static func allowsEncodedByteCount(
        _ byteCount: Int,
        limits: ArtworkResourceLimits
    ) -> Bool {
        byteCount > 0 && byteCount <= limits.maximumEncodedBytes
    }

    static func allowsDecodedFrames(
        _ frames: [ArtworkDecodedFrame],
        limits: ArtworkResourceLimits
    ) -> Bool {
        guard !frames.isEmpty,
              frames.count <= limits.maximumFrameCount,
              limits.maximumDecodedPixels > 0,
              limits.maximumDimension > 0
        else { return false }

        var totalPixels: Int64 = 0
        for frame in frames {
            guard (1...limits.maximumDimension).contains(frame.width),
                  (1...limits.maximumDimension).contains(frame.height),
                  frame.width <= Int64.max / frame.height
            else { return false }
            let pixels = frame.width * frame.height
            guard totalPixels <= limits.maximumDecodedPixels - pixels else { return false }
            totalPixels += pixels
        }
        return true
    }

    static func allowsImageData(
        _ data: Data,
        limits: ArtworkResourceLimits
    ) -> Bool {
        guard allowsEncodedByteCount(data.count, limits: limits) else { return false }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= limits.maximumFrameCount else { return false }
        var frames: [ArtworkDecodedFrame] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else { return false }
            frames.append(
                ArtworkDecodedFrame(
                    width: width.int64Value,
                    height: height.int64Value
                )
            )
        }
        return allowsDecodedFrames(frames, limits: limits)
        #else
        return false
        #endif
    }
}

enum ArtworkNetworkSessionPolicy {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 20

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}

public enum ArtworkRequestPriority: Equatable, Sendable {
    case visible
    case prefetch
}

struct ArtworkDataCacheSnapshot: Equatable, Sendable {
    let inFlightRequestCount: Int
    let visibleRetryCount: Int
    let waiterCount: Int
}

final class ArtworkWaiterCancellation: @unchecked Sendable {
    private enum State {
        case pending
        case registered(@Sendable () -> Void)
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private var state: State = .pending

    /// Returns false when cancellation won before the actor could register
    /// the continuation. Once registered, cancellation invokes exactly one
    /// actor-owned removal action.
    func register(_ action: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            switch state {
            case .pending:
                state = .registered(action)
                return true
            case .cancelled, .finished, .registered:
                return false
            }
        }
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            switch state {
            case .pending:
                state = .cancelled
                return nil
            case let .registered(action):
                state = .cancelled
                return action
            case .cancelled, .finished:
                return nil
            }
        }
        action?()
    }

    func finish() {
        lock.withLock { state = .finished }
    }
}

/// Coalesces artwork requests and retains only bounded encoded image data.
/// Platform views decode it after ImageIO has validated every frame's dimensions.
/// Both unique transports and coalesced waiters are admitted before their Task or
/// continuation is created, so rapid URL churn cannot create an unbounded session
/// or suspended-caller population.
public actor ArtworkDataCache {
    typealias InitialTrustEvaluator = @Sendable (URL) -> Bool
    typealias RequestLoader = @Sendable (URL, ArtworkResourceLimits) async -> Data?

    public static let shared = ArtworkDataCache()

    private struct CacheKey: Hashable, Sendable {
        let url: URL
        let limits: ArtworkResourceLimits
    }

    private struct InFlightRequest {
        let id: UInt64
        var waiters: [UInt64: CheckedContinuation<ArtworkDataAttemptResult, Never>]
        var task: Task<Void, Never>?
        var acceptsWaiters: Bool
        var priority: ArtworkRequestPriority
    }

    private enum ArtworkDataAttemptResult: Sendable {
        case completed(Data?)
        case transientBusy
    }

    private static let absoluteMaximumConcurrentRequests = 12
    private static let absoluteMaximumWaitersPerRequest = 24
    private static let absoluteMaximumVisibleRetries = 24
    private static let maximumVisibleAdmissionRetryAttempts = 420
    private static let visibleAdmissionRetryDelay: Duration = .milliseconds(50)

    private let initialTrustEvaluator: InitialTrustEvaluator
    private let requestLoader: RequestLoader
    private var dataByKey: [CacheKey: Data] = [:]
    private var recency: [CacheKey] = []
    private var inFlight: [CacheKey: InFlightRequest] = [:]
    private var nextRequestID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var visibleRetryCount = 0
    private var totalBytes = 0

    public init() {
        initialTrustEvaluator = { ArtworkURLTrustPolicy.allowsInitialRequest($0) }
        requestLoader = { url, limits in
            await Self.loadValidatedArtwork(from: url, limits: limits)
        }
    }

    init(
        initialTrustEvaluator: @escaping InitialTrustEvaluator,
        requestLoader: @escaping RequestLoader
    ) {
        self.initialTrustEvaluator = initialTrustEvaluator
        self.requestLoader = requestLoader
    }

    public func data(
        for url: URL,
        limits: ArtworkResourceLimits,
        priority: ArtworkRequestPriority = .visible
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let key = CacheKey(url: url, limits: limits)
        if let cached = dataByKey[key] {
            touch(key)
            return cached
        }
        guard initialTrustEvaluator(url) else { return nil }

        var ownsRetrySlot = false
        var retryAttempts = 0
        defer {
            if ownsRetrySlot {
                visibleRetryCount -= 1
            }
        }

        while !Task.isCancelled {
            switch await attemptData(for: key, priority: priority) {
            case let .completed(loaded):
                return Task.isCancelled ? nil : loaded
            case .transientBusy:
                guard priority == .visible else { return nil }
                if !ownsRetrySlot {
                    let retryLimit = activeVisibleRetryLimit(including: limits)
                    guard visibleRetryCount < retryLimit else { return nil }
                    visibleRetryCount += 1
                    ownsRetrySlot = true
                }
                guard retryAttempts < Self.maximumVisibleAdmissionRetryAttempts else {
                    return nil
                }
                retryAttempts += 1
                do {
                    try await Task.sleep(for: Self.visibleAdmissionRetryDelay)
                } catch {
                    return nil
                }
            }
        }
        return nil
    }

    private func attemptData(
        for key: CacheKey,
        priority: ArtworkRequestPriority
    ) async -> ArtworkDataAttemptResult {
        guard !Task.isCancelled else { return .completed(nil) }
        if let cached = dataByKey[key] {
            touch(key)
            return .completed(cached)
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        let cancellation = ArtworkWaiterCancellation()
        let result: ArtworkDataAttemptResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard cancellation.register({
                    Task { await self.cancelWaiter(id: waiterID) }
                }) else {
                    continuation.resume(returning: .completed(nil))
                    return
                }
                registerWaiter(
                    continuation,
                    id: waiterID,
                    for: key,
                    priority: priority
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
        cancellation.finish()
        return Task.isCancelled ? .completed(nil) : result
    }

    public func prefetch(
        _ urls: [URL],
        limits: ArtworkResourceLimits,
        limit: Int = 6
    ) async {
        let admittedLimit = min(
            max(0, limit),
            Self.concurrentRequestLimit(for: limits)
        )
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }.prefix(admittedLimit)
        await withTaskGroup(of: Void.self) { group in
            for url in unique {
                group.addTask {
                    _ = await self.data(
                        for: url,
                        limits: limits,
                        priority: .prefetch
                    )
                }
            }
        }
    }

    func snapshotForTesting() -> ArtworkDataCacheSnapshot {
        ArtworkDataCacheSnapshot(
            inFlightRequestCount: inFlight.count,
            visibleRetryCount: visibleRetryCount,
            waiterCount: inFlight.values.reduce(0) { $0 + $1.waiters.count }
        )
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<ArtworkDataAttemptResult, Never>,
        id waiterID: UInt64,
        for key: CacheKey,
        priority: ArtworkRequestPriority
    ) {
        if var request = inFlight[key] {
            let waiterLimit = Self.waiterLimit(for: key.limits)
            guard request.acceptsWaiters,
                  request.waiters.count < waiterLimit
            else {
                continuation.resume(returning: .transientBusy)
                return
            }
            request.waiters[waiterID] = continuation
            if priority == .visible {
                request.priority = .visible
            }
            inFlight[key] = request
            return
        }

        guard Self.waiterLimit(for: key.limits) > 0,
              canStartRequest(priority: priority, limits: key.limits)
        else {
            continuation.resume(returning: .transientBusy)
            return
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        inFlight[key] = InFlightRequest(
            id: requestID,
            waiters: [waiterID: continuation],
            task: nil,
            acceptsWaiters: true,
            priority: priority
        )

        let requestLoader = self.requestLoader
        let task = Task {
            let loaded = await requestLoader(key.url, key.limits)
            self.completeRequest(id: requestID, for: key, loaded: loaded)
        }
        guard var request = inFlight[key], request.id == requestID else {
            task.cancel()
            return
        }
        request.task = task
        inFlight[key] = request
    }

    private func cancelWaiter(id waiterID: UInt64) {
        guard let key = inFlight.first(where: { $0.value.waiters[waiterID] != nil })?.key,
              var request = inFlight[key],
              let continuation = request.waiters.removeValue(forKey: waiterID)
        else { return }

        if request.waiters.isEmpty {
            // Retain the occupied flight slot until its cancellation reaches the
            // transport completion. A rapid replacement therefore cannot briefly
            // exceed the global live-session bound.
            request.acceptsWaiters = false
            request.task?.cancel()
        }
        inFlight[key] = request
        continuation.resume(returning: .completed(nil))
    }

    private func completeRequest(
        id requestID: UInt64,
        for key: CacheKey,
        loaded: Data?
    ) {
        guard let request = inFlight[key], request.id == requestID else { return }
        inFlight[key] = nil

        let acceptedData = request.acceptsWaiters ? loaded : nil
        if let acceptedData {
            insert(acceptedData, for: key)
        }
        for continuation in request.waiters.values {
            continuation.resume(returning: .completed(acceptedData))
        }
    }

    private func canStartRequest(
        priority: ArtworkRequestPriority,
        limits: ArtworkResourceLimits
    ) -> Bool {
        let activeLimit = activeConcurrentRequestLimit(including: limits)
        guard activeLimit > 0 else { return false }
        switch priority {
        case .visible:
            return inFlight.count < activeLimit
        case .prefetch:
            // A speculative prefetch can never occupy the final transport slot.
            return inFlight.count < max(0, activeLimit - 1)
        }
    }

    private func activeConcurrentRequestLimit(
        including limits: ArtworkResourceLimits
    ) -> Int {
        inFlight.keys.reduce(Self.concurrentRequestLimit(for: limits)) { result, key in
            min(result, Self.concurrentRequestLimit(for: key.limits))
        }
    }

    private static func concurrentRequestLimit(
        for limits: ArtworkResourceLimits
    ) -> Int {
        min(max(limits.maximumConcurrentRequests, 0), absoluteMaximumConcurrentRequests)
    }

    private static func waiterLimit(for limits: ArtworkResourceLimits) -> Int {
        min(max(limits.maximumWaitersPerRequest, 0), absoluteMaximumWaitersPerRequest)
    }

    private func activeVisibleRetryLimit(
        including limits: ArtworkResourceLimits
    ) -> Int {
        inFlight.keys.reduce(Self.visibleRetryLimit(for: limits)) { result, key in
            min(result, Self.visibleRetryLimit(for: key.limits))
        }
    }

    private static func visibleRetryLimit(for limits: ArtworkResourceLimits) -> Int {
        let concurrentLimit = concurrentRequestLimit(for: limits)
        guard concurrentLimit > 0 else { return 0 }
        return min(concurrentLimit * 2, absoluteMaximumVisibleRetries)
    }

    private static func loadValidatedArtwork(
        from url: URL,
        limits: ArtworkResourceLimits
    ) async -> Data? {
        guard ArtworkURLTrustPolicy.allowsInitialRequest(url) else { return nil }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: ArtworkNetworkSessionPolicy.requestTimeout
        )
        urlRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await BoundedHTTPDataLoader.load(
            request: urlRequest,
            maximumBytes: limits.maximumEncodedBytes,
            configuration: ArtworkNetworkSessionPolicy.makeConfiguration(),
            redirectValidator: { sourceURL, destinationURL in
                ArtworkRedirectTrustPolicy.allows(
                    from: sourceURL,
                    to: destinationURL
                )
            }
        ),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.mimeType.map({ $0.lowercased().hasPrefix("image/") }) ?? true,
              ArtworkResourcePolicy.allowsImageData(data, limits: limits)
        else { return nil }
        return data
    }

    private func insert(_ data: Data, for key: CacheKey) {
        if let existing = dataByKey[key] {
            totalBytes -= existing.count
        }
        dataByKey[key] = data
        totalBytes += data.count
        touch(key)
        while recency.count > key.limits.maximumCacheEntries
                || totalBytes > key.limits.maximumCacheBytes,
              let oldest = recency.first {
            recency.removeFirst()
            totalBytes -= dataByKey[oldest]?.count ?? 0
            dataByKey[oldest] = nil
        }
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
