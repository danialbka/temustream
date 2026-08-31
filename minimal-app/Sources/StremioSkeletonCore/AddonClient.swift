import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AddonClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The add-on returned an invalid response."
        case let .httpStatus(status):
            "The add-on returned HTTP \(status)."
        case let .responseTooLarge(limit):
            "The add-on response exceeded the \(limit)-byte safety limit."
        }
    }
}

public protocol HTTPDataLoading: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoading {}

public enum BoundedHTTPRedirectPolicy: Equatable, Sendable {
    case follow
    case reject
}

public enum BoundedHTTPDataLoaderError: LocalizedError, Equatable {
    case invalidResponse
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid HTTP response."
        case let .responseTooLarge(limit):
            "The response exceeded the \(limit)-byte safety limit."
        }
    }
}

private struct BoundedHTTPOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty
        else { return nil }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// Prevents an Internet response from turning the process into a private-network
/// HTTP client through a cross-origin redirect. Same-origin redirects remain
/// usable for explicitly configured local servers; a new origin must resolve
/// exclusively to public addresses and HTTPS may not be downgraded to HTTP.
enum BoundedHTTPRedirectTrustPolicy {
    static func allows(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard destinationURL.user == nil,
              destinationURL.password == nil,
              let source = BoundedHTTPOrigin(sourceURL),
              let destination = BoundedHTTPOrigin(destinationURL)
        else { return false }

        if source == destination {
            return true
        }
        guard !(source.scheme == "https" && destination.scheme == "http"),
              !isLocalHostname(destination.host),
              let addresses = resolvedAddresses(for: destination.host),
              !addresses.isEmpty,
              !addresses.contains(where: isRestrictedAddress)
        else { return false }
        return true
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
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return true
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isRestrictedAddress(Array(bytes.suffix(4)))
        }
        return false
    }
}

/// Downloads an HTTP response without ever retaining more than the caller's
/// byte budget. Non-success HTTP responses are returned from their headers
/// without materializing an error page, so callers can preserve status-based
/// retry and redirect behavior.
public final class BoundedHTTPDataLoader: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let maximumBytes: Int
    private let redirectPolicy: BoundedHTTPRedirectPolicy
    private let preservedRedirectHeaders: [String: String]
    private let redirectValidator: @Sendable (URL, URL) -> Bool
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var deadlineWorkItem: DispatchWorkItem?
    private var finished = false

    init(
        maximumBytes: Int,
        redirectPolicy: BoundedHTTPRedirectPolicy,
        preservedRedirectHeaders: [String: String],
        redirectValidator: @escaping @Sendable (URL, URL) -> Bool = {
            BoundedHTTPRedirectTrustPolicy.allows(from: $0, to: $1)
        }
    ) {
        self.maximumBytes = maximumBytes
        self.redirectPolicy = redirectPolicy
        self.preservedRedirectHeaders = preservedRedirectHeaders
        self.redirectValidator = redirectValidator
    }

    public static func load(
        request: URLRequest,
        maximumBytes: Int,
        configuration: URLSessionConfiguration = .ephemeral,
        redirectPolicy: BoundedHTTPRedirectPolicy = .follow,
        preserveHeadersAcrossRedirects headerNames: [String] = [],
        redirectValidator: (@Sendable (URL, URL) -> Bool)? = nil,
        operationTimeout: TimeInterval? = nil
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else {
            throw BoundedHTTPDataLoaderError.responseTooLarge(maximumBytes)
        }
        if let operationTimeout,
           !operationTimeout.isFinite || operationTimeout <= 0 {
            throw URLError(.timedOut)
        }
        try Task.checkCancellation()
        let preservedHeaders = Dictionary(
            uniqueKeysWithValues: headerNames.compactMap { name in
                request.value(forHTTPHeaderField: name).map { (name, $0) }
            }
        )
        let loader = BoundedHTTPDataLoader(
            maximumBytes: maximumBytes,
            redirectPolicy: redirectPolicy,
            preservedRedirectHeaders: preservedHeaders,
            redirectValidator: redirectValidator ?? {
                BoundedHTTPRedirectTrustPolicy.allows(from: $0, to: $1)
            }
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(
                    request: request,
                    configuration: configuration,
                    operationTimeout: operationTimeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func start(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        operationTimeout: TimeInterval?,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        let deadlineWorkItem = operationTimeout.map { _ in
            DispatchWorkItem { [weak self] in
                self?.finish(.failure(URLError(.timedOut)))
            }
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        self.deadlineWorkItem = deadlineWorkItem
        lock.unlock()
        let task = session.dataTask(with: request)
        task.resume()
        if let operationTimeout, let deadlineWorkItem {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + operationTimeout,
                execute: deadlineWorkItem
            )
        }
    }

    private func cancel() {
        finish(.failure(CancellationError()))
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard redirectPolicy == .follow else {
            completionHandler(nil)
            return
        }
        guard let sourceURL = response.url,
              let destinationURL = request.url,
              redirectValidator(sourceURL, destinationURL)
        else {
            completionHandler(nil)
            return
        }
        let crossesOrigin = BoundedHTTPOrigin(sourceURL) != BoundedHTTPOrigin(destinationURL)
        let originalMethod = task.currentRequest?.httpMethod?.uppercased()
            ?? request.httpMethod?.uppercased()
            ?? "GET"
        guard !crossesOrigin || originalMethod == "GET" || originalMethod == "HEAD" else {
            completionHandler(nil)
            return
        }
        var redirected = request
        let sensitiveHeaders = ["Authorization", "Cookie", "Proxy-Authorization"]
        if crossesOrigin {
            for name in sensitiveHeaders {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
        }
        for (name, value) in preservedRedirectHeaders
        where redirected.value(forHTTPHeaderField: name) == nil
            && (!crossesOrigin || !sensitiveHeaders.contains {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
            redirected.setValue(value, forHTTPHeaderField: name)
        }
        completionHandler(redirected)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(BoundedHTTPDataLoaderError.invalidResponse))
            return
        }
        lock.withLock { self.response = http }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.success((Data(), http)))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(BoundedHTTPDataLoaderError.responseTooLarge(maximumBytes)))
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive chunk: Data
    ) {
        let exceeded = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard chunk.count <= maximumBytes - data.count else { return true }
            data.append(chunk)
            return false
        }
        if exceeded {
            dataTask.cancel()
            finish(.failure(BoundedHTTPDataLoaderError.responseTooLarge(maximumBytes)))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        let result = lock.withLock { () -> Result<(Data, URLResponse), Error> in
            guard let response else {
                return .failure(BoundedHTTPDataLoaderError.invalidResponse)
            }
            return .success((data, response))
        }
        finish(result)
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        let state = lock.withLock { () -> (
            CheckedContinuation<(Data, URLResponse), Error>?,
            URLSession?,
            DispatchWorkItem?
        ) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            let deadlineWorkItem = self.deadlineWorkItem
            self.deadlineWorkItem = nil
            return (continuation, session, deadlineWorkItem)
        }
        state.2?.cancel()
        state.1?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
}

public struct AddonClient: Sendable {
    private enum ResponseLimit {
        static let manifest = 1 * 1024 * 1024
        static let catalog = 8 * 1024 * 1024
        static let meta = 4 * 1024 * 1024
        static let streams = 4 * 1024 * 1024
        static let subtitles = 8 * 1024 * 1024
    }

    public let endpoint: AddonEndpoint
    private let loader: any HTTPDataLoading
    private let decoder: JSONDecoder
    private let requestTimeout: TimeInterval

    public init(
        endpoint: AddonEndpoint,
        loader: any HTTPDataLoading = URLSession.shared,
        requestTimeout: TimeInterval = 12
    ) {
        self.endpoint = endpoint
        self.loader = loader
        self.requestTimeout = Self.normalizedRequestTimeout(requestTimeout)
        decoder = JSONDecoder()
    }

    static func boundedSessionConfiguration(
        requestTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let timeout = normalizedRequestTimeout(requestTimeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    private static func normalizedRequestTimeout(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 12
    }

    public func manifest() async throws -> AddonManifest {
        try await fetch(
            AddonManifest.self,
            from: endpoint.manifestURL,
            maximumBytes: ResponseLimit.manifest
        )
    }

    public func catalog(
        type: String,
        id: String,
        search: String? = nil,
        skip: Int? = nil
    ) async throws -> [MetaItem] {
        let url = try endpoint.catalogURL(type: type, id: id, search: search, skip: skip)
        return try await fetch(
            CatalogResponse.self,
            from: url,
            maximumBytes: ResponseLimit.catalog
        ).metas
    }

    public func meta(type: String, id: String) async throws -> MetaItem {
        try await fetch(
            MetaResponse.self,
            from: endpoint.metaURL(type: type, id: id),
            maximumBytes: ResponseLimit.meta
        ).meta
    }

    public func streams(type: String, id: String) async throws -> [Stream] {
        try await fetch(
            StreamResponse.self,
            from: endpoint.streamURL(type: type, id: id),
            maximumBytes: ResponseLimit.streams
        ).streams
    }

    public func subtitles(type: String, id: String) async throws -> [Subtitle] {
        try await fetch(
            SubtitleResponse.self,
            from: endpoint.subtitlesURL(type: type, id: id),
            maximumBytes: ResponseLimit.subtitles
        )
            .subtitles
    }

    private func fetch<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        maximumBytes: Int
    ) async throws -> Value {
        let dataAndResponse: (Data, URLResponse)
        if loader is URLSession {
            var request = URLRequest(url: url)
            request.timeoutInterval = requestTimeout
            let configuration = Self.boundedSessionConfiguration(
                requestTimeout: requestTimeout
            )
            do {
                dataAndResponse = try await BoundedHTTPDataLoader.load(
                    request: request,
                    maximumBytes: maximumBytes,
                    configuration: configuration,
                    operationTimeout: requestTimeout
                )
            } catch BoundedHTTPDataLoaderError.invalidResponse {
                throw AddonClientError.invalidResponse
            } catch BoundedHTTPDataLoaderError.responseTooLarge {
                throw AddonClientError.responseTooLarge(maximumBytes)
            }
        } else {
            dataAndResponse = try await loader.data(from: url)
        }
        let (data, response) = dataAndResponse
        guard data.count <= maximumBytes else {
            throw AddonClientError.responseTooLarge(maximumBytes)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AddonClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AddonClientError.httpStatus(http.statusCode)
        }
        return try decoder.decode(type, from: data)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
