import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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

/// Downloads an HTTP response without ever retaining more than the caller's
/// byte budget. Non-success HTTP responses are returned from their headers
/// without materializing an error page, so callers can preserve status-based
/// retry and redirect behavior.
public final class BoundedHTTPDataLoader: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let maximumBytes: Int
    private let redirectPolicy: BoundedHTTPRedirectPolicy
    private let preservedRedirectHeaders: [String: String]
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var finished = false

    init(
        maximumBytes: Int,
        redirectPolicy: BoundedHTTPRedirectPolicy,
        preservedRedirectHeaders: [String: String]
    ) {
        self.maximumBytes = maximumBytes
        self.redirectPolicy = redirectPolicy
        self.preservedRedirectHeaders = preservedRedirectHeaders
    }

    public static func load(
        request: URLRequest,
        maximumBytes: Int,
        configuration: URLSessionConfiguration = .ephemeral,
        redirectPolicy: BoundedHTTPRedirectPolicy = .follow,
        preserveHeadersAcrossRedirects headerNames: [String] = []
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else {
            throw BoundedHTTPDataLoaderError.responseTooLarge(maximumBytes)
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
            preservedRedirectHeaders: preservedHeaders
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(
                    request: request,
                    configuration: configuration,
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
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        lock.unlock()
        session.dataTask(with: request).resume()
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
        var redirected = request
        for (name, value) in preservedRedirectHeaders
        where redirected.value(forHTTPHeaderField: name) == nil {
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
            URLSession?
        ) in
            guard !finished else { return (nil, nil) }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            return (continuation, session)
        }
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
        self.requestTimeout = requestTimeout
        decoder = JSONDecoder()
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
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            do {
                dataAndResponse = try await BoundedHTTPDataLoader.load(
                    request: request,
                    maximumBytes: maximumBytes,
                    configuration: configuration
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
