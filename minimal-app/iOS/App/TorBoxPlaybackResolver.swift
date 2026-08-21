import Foundation

enum TorBoxPlaybackError: LocalizedError {
    case rejected(Int)
    case nonMediaResponse(String)
    case invalidRedirect

    var errorDescription: String? {
        switch self {
        case let .rejected(status):
            "TorBox rejected the stream request (HTTP \(status))."
        case let .nonMediaResponse(type):
            "TorBox returned \(type) instead of a media stream."
        case .invalidRedirect:
            "TorBox returned an invalid redirect."
        }
    }
}

private final class TorBoxRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Resolves TorBox permalinks immediately before playback. TorBox's API docs
/// recommend keeping requestdl permalinks and following them to a short-lived
/// CDN URL instead of saving the CDN URL. A two-byte range request both follows
/// that redirect and primes the CDN without downloading the movie twice.
enum TorBoxPlaybackResolver {
    static func shouldResolve(stream: Stream, url: URL, providerName: String? = nil) -> Bool {
        if url.host?.localizedCaseInsensitiveContains("torbox") == true {
            return true
        }
        let metadata = [providerName, stream.name, stream.title, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return metadata.contains("torbox")
            || metadata.contains("scraper tb")
            || metadata.contains("[tb]")
    }

    static func resolve(_ input: URL) async throws -> URL {
        var url = input
        if input.host?.caseInsensitiveCompare("api.torbox.app") == .orderedSame,
           input.path.localizedCaseInsensitiveContains("/requestdl") {
            var components = URLComponents(url: input, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.removeAll { $0.name.caseInsensitiveCompare("redirect") == .orderedSame }
            items.append(URLQueryItem(name: "redirect", value: "true"))
            components?.queryItems = items
            url = components?.url ?? input
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let redirectBlocker = TorBoxRedirectBlocker()
        for _ in 0..<6 {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (_, response) = try await session.data(
                for: request,
                delegate: redirectBlocker
            )
            guard let http = response as? HTTPURLResponse else { return url }

            if (300...399).contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let redirected = URL(string: location, relativeTo: url)?.absoluteURL
                else {
                    throw TorBoxPlaybackError.invalidRedirect
                }
                url = redirected
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                throw TorBoxPlaybackError.rejected(http.statusCode)
            }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            if contentType.contains("application/json") || contentType.contains("text/html") {
                throw TorBoxPlaybackError.nonMediaResponse(contentType)
            }
            return url
        }
        throw TorBoxPlaybackError.invalidRedirect
    }
}
