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

    public init(
        id: String,
        type: String,
        name: String,
        poster: URL? = nil,
        background: URL? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        genres: [String]? = nil,
        videos: [Video]? = nil
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
    }
}

public struct Video: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let season: Int?
    public let episode: Int?
    public let released: String?
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
