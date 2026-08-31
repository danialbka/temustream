import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Applies a hard response-body budget to production URLSession requests and
/// also verifies bodies returned by injected loaders used in tests.
enum HTTPRequestBodyLoader {
    static func load(
        using loader: any HTTPRequestLoading,
        request: URLRequest,
        maximumBytes: Int,
        redirectPolicy: BoundedHTTPRedirectPolicy = .follow
    ) async throws -> (Data, URLResponse) {
        let result: (Data, URLResponse)
        if let session = loader as? URLSession {
            let configuration = session.configuration
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let operationTimeout = normalizedOperationTimeout(
                request: request,
                configuration: configuration
            )
            configuration.timeoutIntervalForRequest = operationTimeout
            configuration.timeoutIntervalForResource = operationTimeout
            result = try await BoundedHTTPDataLoader.load(
                request: request,
                maximumBytes: maximumBytes,
                configuration: configuration,
                redirectPolicy: redirectPolicy,
                operationTimeout: operationTimeout
            )
        } else {
            // Injected loaders own their transport and cancellation policy.
            // Every shipped call site uses URLSession and therefore takes the
            // bounded production path above; the post-completion byte check is
            // still retained for deterministic test seams.
            result = try await loader.data(for: request)
        }
        guard result.0.count <= maximumBytes else {
            throw BoundedHTTPDataLoaderError.responseTooLarge(maximumBytes)
        }
        return result
    }

    private static func normalizedOperationTimeout(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) -> TimeInterval {
        let candidates = [
            request.timeoutInterval,
            configuration.timeoutIntervalForRequest,
            configuration.timeoutIntervalForResource,
        ].filter { $0.isFinite && $0 > 0 }
        return candidates.min() ?? 60
    }
}
