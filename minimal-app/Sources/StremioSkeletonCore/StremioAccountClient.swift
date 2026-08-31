import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct StremioUser: Codable, Equatable, Sendable {
    public let id: String?
    public let email: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case email
    }
}

public struct StremioSession: Codable, Equatable, Sendable {
    public let authKey: String
    public let user: StremioUser
}

public struct RemoteLibraryItem: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let poster: URL?
    public let removed: Bool
    public let temp: Bool
    public let ctime: String?
    public let mtime: String
    public let state: State
    public let posterShape: String
    public let behaviorHints: BehaviorHints

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, type, poster, removed, temp
        case ctime = "_ctime"
        case mtime = "_mtime"
        case state, posterShape, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(String.self, forKey: .type)
        poster = Self.decodeOptionalURL(from: values, forKey: .poster)
        removed = try values.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        temp = try values.decodeIfPresent(Bool.self, forKey: .temp) ?? false
        ctime = try values.decodeIfPresent(String.self, forKey: .ctime)
        mtime = try values.decodeIfPresent(String.self, forKey: .mtime)
            ?? ctime
            ?? "1970-01-01T00:00:00Z"
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? State()
        posterShape = try values.decodeIfPresent(String.self, forKey: .posterShape) ?? "poster"
        behaviorHints = try values.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)
            ?? BehaviorHints()
    }

    private static func decodeOptionalURL(
        from values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> URL? {
        guard let rawValue = try? values.decodeIfPresent(String.self, forKey: key),
              !rawValue.isEmpty,
              let url = URL(string: rawValue),
              url.scheme != nil
        else { return nil }
        return url
    }

    public struct State: Codable, Equatable, Sendable {
        public let lastWatched: String?
        public let timeWatched: UInt64
        public let timeOffset: UInt64
        public let overallTimeWatched: UInt64
        public let timesWatched: UInt32
        public let flaggedWatched: UInt32
        public let duration: UInt64
        public let videoID: String?
        public let watched: String?
        public let noNotif: Bool

        enum CodingKeys: String, CodingKey {
            case lastWatched, timeWatched, timeOffset, overallTimeWatched
            case timesWatched, flaggedWatched, duration
            case videoID = "video_id"
            case watched, noNotif
        }

        public init() {
            lastWatched = nil
            timeWatched = 0
            timeOffset = 0
            overallTimeWatched = 0
            timesWatched = 0
            flaggedWatched = 0
            duration = 0
            videoID = nil
            watched = nil
            noNotif = false
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lastWatched = try? values.decodeIfPresent(String.self, forKey: .lastWatched)
            timeWatched = try values.decodeIfPresent(UInt64.self, forKey: .timeWatched) ?? 0
            timeOffset = try values.decodeIfPresent(UInt64.self, forKey: .timeOffset) ?? 0
            overallTimeWatched = try values.decodeIfPresent(UInt64.self, forKey: .overallTimeWatched) ?? 0
            timesWatched = try values.decodeIfPresent(UInt32.self, forKey: .timesWatched) ?? 0
            flaggedWatched = try values.decodeIfPresent(UInt32.self, forKey: .flaggedWatched) ?? 0
            duration = try values.decodeIfPresent(UInt64.self, forKey: .duration) ?? 0
            videoID = try? values.decodeIfPresent(String.self, forKey: .videoID)
            watched = try? values.decodeIfPresent(String.self, forKey: .watched)
            noNotif = try values.decodeIfPresent(Bool.self, forKey: .noNotif) ?? false
        }
    }

    public struct BehaviorHints: Codable, Equatable, Sendable {
        public let defaultVideoID: String?
        public let featuredVideoID: String?
        public let hasScheduledVideos: Bool

        enum CodingKeys: String, CodingKey {
            case defaultVideoID = "defaultVideoId"
            case featuredVideoID = "featuredVideoId"
            case hasScheduledVideos
        }

        public init() {
            defaultVideoID = nil
            featuredVideoID = nil
            hasScheduledVideos = false
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            defaultVideoID = try? values.decodeIfPresent(String.self, forKey: .defaultVideoID)
            featuredVideoID = try? values.decodeIfPresent(String.self, forKey: .featuredVideoID)
            hasScheduledVideos = try values.decodeIfPresent(Bool.self, forKey: .hasScheduledVideos)
                ?? false
        }
    }

    public init(item: MetaItem, removed: Bool, date: Date = Date()) {
        id = item.id
        name = item.name
        type = item.type
        poster = item.poster
        self.removed = removed
        temp = false
        let timestamp = ISO8601DateFormatter().string(from: date)
        ctime = timestamp
        mtime = timestamp
        state = State()
        posterShape = "poster"
        behaviorHints = BehaviorHints()
    }

    public var metaItem: MetaItem {
        MetaItem(id: id, type: type, name: name, poster: poster)
    }
}

public struct SyncedAddon: Codable, Equatable, Sendable {
    public let manifest: AddonManifest
    public let transportUrl: URL
    public let flags: Flags

    public init(manifest: AddonManifest, transportUrl: URL) {
        self.manifest = manifest
        self.transportUrl = transportUrl
        flags = Flags()
    }

    enum CodingKeys: String, CodingKey {
        case manifest, transportUrl, flags
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try values.decode(AddonManifest.self, forKey: .manifest)
        transportUrl = try values.decode(URL.self, forKey: .transportUrl)
        flags = try values.decodeIfPresent(Flags.self, forKey: .flags) ?? Flags()
    }

    public struct Flags: Codable, Equatable, Sendable {
        public let official: Bool
        public let protected: Bool

        public init(official: Bool = false, protected: Bool = false) {
            self.official = official
            self.protected = protected
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            official = try values.decodeIfPresent(Bool.self, forKey: .official) ?? false
            protected = try values.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case official, protected
        }
    }
}

public enum StremioAccountError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case api(String)
    case updateRejected
    case decoding(method: String, path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The Stremio API endpoint must use HTTPS or localhost HTTP."
        case .invalidResponse: "Stremio returned an invalid account response."
        case let .httpStatus(status): "Stremio returned HTTP \(status)."
        case let .api(message): message
        case .updateRejected: "Stremio rejected the account update."
        case let .decoding(method, path, reason):
            "Stremio \(method) returned incompatible data at \(path): \(reason)."
        }
    }
}

public struct StremioAccountClient: Sendable {
    private enum ResponseLimit {
        static let ordinary = 2 * 1024 * 1024
        static let addons = 8 * 1024 * 1024
        static let library = 32 * 1024 * 1024

        static func bytes(for method: String) -> Int {
            switch method {
            case "datastoreGet": library
            case "addonCollectionGet": addons
            default: ordinary
            }
        }
    }

    public let endpoint: URL
    private let loader: any HTTPRequestLoading
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        endpoint: URL = URL(string: "https://api.strem.io")!,
        loader: any HTTPRequestLoading = URLSession.shared
    ) throws {
        guard endpoint.scheme == "https" ||
                (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(endpoint.host))
        else { throw StremioAccountError.invalidEndpoint }
        self.endpoint = endpoint
        self.loader = loader
    }

    public func login(email: String, password: String) async throws -> StremioSession {
        try await post(
            "login",
            body: LoginRequest(email: email, password: password, facebook: false),
            as: StremioSession.self
        )
    }

    public func pullLibrary(authKey: String) async throws -> [RemoteLibraryItem] {
        try await post(
            "datastoreGet",
            body: DatastoreGetRequest(
                authKey: authKey,
                collection: "libraryItem",
                ids: [],
                all: true
            ),
            as: [RemoteLibraryItem].self
        )
    }

    public func pushLibrary(authKey: String, changes: [RemoteLibraryItem]) async throws {
        let acknowledgement = try await post(
            "datastorePut",
            body: DatastorePutRequest(
                authKey: authKey,
                collection: "libraryItem",
                changes: changes
            ),
            as: SuccessResult.self
        )
        guard acknowledgement.success else {
            throw StremioAccountError.updateRejected
        }
    }

    public func pullAddons(authKey: String) async throws -> [SyncedAddon] {
        try await post(
            "addonCollectionGet",
            body: AddonGetRequest(authKey: authKey, update: true),
            as: AddonCollection.self
        ).addons
    }

    public func pushAddons(authKey: String, addons: [SyncedAddon]) async throws {
        let acknowledgement = try await post(
            "addonCollectionSet",
            body: AddonSetRequest(authKey: authKey, addons: addons),
            as: SuccessResult.self
        )
        guard acknowledgement.success else {
            throw StremioAccountError.updateRejected
        }
    }

    private func post<Body: Encodable, Value: Decodable>(
        _ method: String,
        body: Body,
        as type: Value.Type
    ) async throws -> Value {
        let url = endpoint.appendingPathComponent("api").appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await HTTPRequestBodyLoader.load(
            using: loader,
            request: request,
            maximumBytes: ResponseLimit.bytes(for: method),
            redirectPolicy: .reject
        )
        guard let http = response as? HTTPURLResponse else {
            throw StremioAccountError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StremioAccountError.httpStatus(http.statusCode)
        }
        let envelope: APIEnvelope<Value>
        do {
            envelope = try decoder.decode(APIEnvelope<Value>.self, from: data)
        } catch let error as DecodingError {
            let details = Self.describe(error)
            throw StremioAccountError.decoding(
                method: method,
                path: details.path,
                reason: details.reason
            )
        }
        if let error = envelope.error { throw StremioAccountError.api(error.message) }
        guard let result = envelope.result else { throw StremioAccountError.invalidResponse }
        return result
    }

    private static func describe(_ error: DecodingError) -> (path: String, reason: String) {
        let codingPath: [any CodingKey]
        let reason: String
        switch error {
        case let .dataCorrupted(context):
            codingPath = context.codingPath
            reason = "invalid value"
        case let .keyNotFound(key, context):
            codingPath = context.codingPath + [key]
            reason = "missing required field"
        case let .typeMismatch(type, context):
            codingPath = context.codingPath
            reason = "expected \(String(describing: type))"
        case let .valueNotFound(type, context):
            codingPath = context.codingPath
            reason = "missing \(String(describing: type)) value"
        @unknown default:
            codingPath = []
            reason = "unsupported response shape"
        }
        let path = codingPath.isEmpty
            ? "result"
            : codingPath.map(\.stringValue).joined(separator: ".")
        return (path, reason)
    }
}

private struct APIEnvelope<Value: Decodable>: Decodable {
    let result: Value?
    let error: APIErrorPayload?
}

private struct APIErrorPayload: Decodable {
    let message: String
}

private struct LoginRequest: Encodable {
    let email: String
    let password: String
    let facebook: Bool
}

private struct DatastoreGetRequest: Encodable {
    let authKey: String
    let collection: String
    let ids: [String]
    let all: Bool
}

private struct DatastorePutRequest: Encodable {
    let authKey: String
    let collection: String
    let changes: [RemoteLibraryItem]
}

private struct AddonGetRequest: Encodable {
    let authKey: String
    let update: Bool
}

private struct AddonSetRequest: Encodable {
    let authKey: String
    let addons: [SyncedAddon]
}

private struct AddonCollection: Decodable {
    let addons: [SyncedAddon]
}

private struct SuccessResult: Decodable {
    let success: Bool
}
