import Foundation

public struct AddonManifest: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let name: String
    public let description: String?
    public let resources: [AddonResource]
    public let types: [String]
    public let catalogs: [AddonCatalog]

    public init(
        id: String,
        version: String,
        name: String,
        description: String? = nil,
        resources: [AddonResource],
        types: [String],
        catalogs: [AddonCatalog]
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.resources = resources
        self.types = types
        self.catalogs = catalogs
    }

    public func supports(resource requestedResource: String, type requestedType: String) -> Bool {
        resources.contains { resource in
            switch resource {
            case let .name(name):
                return name == requestedResource
                    && (types.isEmpty || types.contains(requestedType))
            case let .descriptor(descriptor):
                let supportedTypes = descriptor.types ?? types
                return descriptor.name == requestedResource
                    && (supportedTypes.isEmpty || supportedTypes.contains(requestedType))
            }
        }
    }
}

public enum AddonResource: Codable, Equatable, Sendable {
    case name(String)
    case descriptor(ResourceDescriptor)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .name(name)
        } else {
            self = .descriptor(try container.decode(ResourceDescriptor.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .name(name):
            try container.encode(name)
        case let .descriptor(descriptor):
            try container.encode(descriptor)
        }
    }
}

public struct ResourceDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let types: [String]?
    public let idPrefixes: [String]?
}

public struct AddonCatalog: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    public let id: String
    public let name: String?
    public let extra: [CatalogExtra]?
}

public struct CatalogExtra: Codable, Equatable, Sendable {
    public let name: String
    public let isRequired: Bool?
    public let options: [String]?
    public let optionsLimit: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case isRequired = "isRequired"
        case options
        case optionsLimit
    }
}

public struct MetaItem: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let name: String
    public let poster: URL?
    public let background: URL?
    public let description: String?
    public let releaseInfo: String?
    public let genres: [String]?
    public let videos: [Video]?
    public let trailerStreams: [TrailerStream]?
    public let trailers: [TrailerReference]?

    public init(
        id: String,
        type: String,
        name: String,
        poster: URL? = nil,
        background: URL? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        genres: [String]? = nil,
        videos: [Video]? = nil,
        trailerStreams: [TrailerStream]? = nil,
        trailers: [TrailerReference]? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.description = description
        self.releaseInfo = releaseInfo
        self.genres = genres
        self.videos = videos
        self.trailerStreams = trailerStreams
        self.trailers = trailers
    }

    public var preferredTrailerURL: URL? {
        trailerStreams?.compactMap(\.playbackURL).first
            ?? trailers?.first(where: { trailer in
                trailer.type?.localizedCaseInsensitiveContains("trailer") != false
            })?.playbackURL
            ?? trailers?.compactMap(\.playbackURL).first
    }

    public func fillingTrailerMetadata(from fallback: MetaItem) -> MetaItem {
        guard preferredTrailerURL == nil, fallback.preferredTrailerURL != nil else {
            return self
        }
        return MetaItem(
            id: id,
            type: type,
            name: name,
            poster: poster,
            background: background,
            description: description,
            releaseInfo: releaseInfo,
            genres: genres,
            videos: videos,
            trailerStreams: fallback.trailerStreams,
            trailers: fallback.trailers
        )
    }
}

public struct TrailerStream: Codable, Equatable, Hashable, Sendable {
    public let title: String?
    public let youtubeID: String?
    public let url: URL?

    enum CodingKeys: String, CodingKey {
        case title
        case youtubeID = "ytId"
        case url
    }

    public init(title: String? = nil, youtubeID: String? = nil, url: URL? = nil) {
        self.title = title
        self.youtubeID = youtubeID
        self.url = url
    }

    public var playbackURL: URL? {
        url ?? Self.youtubeURL(for: youtubeID)
    }

    fileprivate static func youtubeURL(for identifier: String?) -> URL? {
        guard let identifier = identifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !identifier.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: identifier)]
        return components?.url
    }
}

public struct TrailerReference: Codable, Equatable, Hashable, Sendable {
    public let source: String?
    public let type: String?

    public init(source: String? = nil, type: String? = nil) {
        self.source = source
        self.type = type
    }

    public var playbackURL: URL? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty
        else { return nil }
        if let url = URL(string: source),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return url
        }
        return TrailerStream.youtubeURL(for: source)
    }
}

public struct Video: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let season: Int?
    public let episode: Int?
    public let thumbnail: URL?
    public let released: String?

    public init(
        id: String,
        title: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        thumbnail: URL? = nil,
        released: String? = nil
    ) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.released = released
    }
}

public struct Stream: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let url: URL?
    public let externalUrl: URL?
    public let name: String?
    public let title: String?
    public let description: String?
    public let infoHash: String?
    public let fileIdx: Int?
    public let sources: [String]?

    public var id: String {
        [url?.absoluteString, externalUrl?.absoluteString, infoHash, name, title]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    public var displayName: String {
        title ?? name ?? url?.host ?? externalUrl?.host ?? "Stream"
    }

    public var isDirectlyPlayable: Bool { url != nil }
    public var isTorrent: Bool { infoHash != nil }

    /// Streams that should be remuxed or transcoded before they reach AVPlayer.
    /// Torrent files are treated as unknown containers because the raw server URL
    /// does not retain the selected file's extension.
    public var prefersCompatibilityPlayback: Bool {
        if isTorrent { return true }

        let hint = [
            url?.pathExtension,
            url?.lastPathComponent,
            name,
            title,
            description,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let unsupportedContainers = [".mkv", ".webm", ".avi", ".flv", ".wmv"]
        let compatibilityCodecs = ["av1", "flac", "truehd", "dts"]
        return unsupportedContainers.contains(where: hint.contains)
            || compatibilityCodecs.contains(where: hint.contains)
    }
}

public struct Subtitle: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String?
    public let url: URL
    public let lang: String

    public var stableID: String { id ?? "\(lang)|\(url.absoluteString)" }
}

public struct CatalogResponse: Codable, Equatable, Sendable {
    public let metas: [MetaItem]

    public init(metas: [MetaItem]) {
        self.metas = metas
    }
}

public struct MetaResponse: Codable, Equatable, Sendable {
    public let meta: MetaItem
}

public struct StreamResponse: Codable, Equatable, Sendable {
    public let streams: [Stream]
}

public struct SubtitleResponse: Codable, Equatable, Sendable {
    public let subtitles: [Subtitle]
}
