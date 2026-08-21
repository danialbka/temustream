import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AddonClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The add-on returned an invalid response."
        case let .httpStatus(status):
            "The add-on returned HTTP \(status)."
        }
    }
}

public protocol HTTPDataLoading: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoading {}

public struct AddonClient: Sendable {
    public let endpoint: AddonEndpoint
    private let loader: any HTTPDataLoading
    private let decoder: JSONDecoder
    private let requestTimeout: TimeInterval

    public init(
        endpoint: AddonEndpoint,
        loader: any HTTPDataLoading = URLSession.shared,
        requestTimeout: TimeInterval = 6
    ) {
        self.endpoint = endpoint
        self.loader = loader
        self.requestTimeout = requestTimeout
        decoder = JSONDecoder()
    }

    public func manifest() async throws -> AddonManifest {
        try await fetch(AddonManifest.self, from: endpoint.manifestURL)
    }

    public func catalog(
        type: String,
        id: String,
        search: String? = nil,
        skip: Int? = nil
    ) async throws -> [MetaItem] {
        let url = try endpoint.catalogURL(type: type, id: id, search: search, skip: skip)
        return try await fetch(CatalogResponse.self, from: url).metas
    }

    public func meta(type: String, id: String) async throws -> MetaItem {
        try await fetch(MetaResponse.self, from: endpoint.metaURL(type: type, id: id)).meta
    }

    public func streams(type: String, id: String) async throws -> [Stream] {
        try await fetch(StreamResponse.self, from: endpoint.streamURL(type: type, id: id)).streams
    }

    public func subtitles(type: String, id: String) async throws -> [Subtitle] {
        try await fetch(SubtitleResponse.self, from: endpoint.subtitlesURL(type: type, id: id))
            .subtitles
    }

    private func fetch<Value: Decodable>(_ type: Value.Type, from url: URL) async throws -> Value {
        let dataAndResponse: (Data, URLResponse)
        if let session = loader as? URLSession {
            var request = URLRequest(url: url)
            request.timeoutInterval = requestTimeout
            dataAndResponse = try await session.data(for: request)
        } else {
            dataAndResponse = try await loader.data(from: url)
        }
        let (data, response) = dataAndResponse
        guard let http = response as? HTTPURLResponse else {
            throw AddonClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AddonClientError.httpStatus(http.statusCode)
        }
        return try decoder.decode(type, from: data)
    }
}
