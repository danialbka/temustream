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

/// Community metadata add-ons are not consistent about whether trivia is a
/// single string or an array. Decode both without allowing an unfamiliar value
/// shape to make the title's entire metadata response fail.
public struct MetadataTextList: Codable, Equatable, Hashable, Sendable {
    public let values: [String]

    public init(_ values: [String]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            values = []
            return
        }
        if let decodedValues = try? container.decode([String].self) {
            values = decodedValues
        } else if let decodedValue = try? container.decode(String.self) {
            values = [decodedValue]
        } else {
            values = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
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
    public let cast: [String]?
    public let actors: [String]?
    public let runtime: String?
    public let imdbRating: String?
    public let director: [String]?
    public let writer: [String]?
    public let country: String?
    public let language: String?
    public let certification: String?
    public let awards: String?
    public let status: String?
    public let released: String?
    public let trivia: MetadataTextList?
    public let funFacts: MetadataTextList?
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
        cast: [String]? = nil,
        actors: [String]? = nil,
        runtime: String? = nil,
        imdbRating: String? = nil,
        director: [String]? = nil,
        writer: [String]? = nil,
        country: String? = nil,
        language: String? = nil,
        certification: String? = nil,
        awards: String? = nil,
        status: String? = nil,
        released: String? = nil,
        trivia: [String]? = nil,
        funFacts: [String]? = nil,
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
        self.cast = cast
        self.actors = actors
        self.runtime = runtime
        self.imdbRating = imdbRating
        self.director = director
        self.writer = writer
        self.country = country
        self.language = language
        self.certification = certification
        self.awards = awards
        self.status = status
        self.released = released
        self.trivia = trivia.map(MetadataTextList.init)
        self.funFacts = funFacts.map(MetadataTextList.init)
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

    /// Stremio metadata normally calls this field `cast`; a few community
    /// add-ons use `actors`. Merge both spellings while keeping provider order.
    public var actorNames: [String] {
        ((cast ?? []) + (actors ?? []))
            .reduce(into: [String]()) { names, rawName in
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                else { return }
                names.append(name)
            }
    }

    public var explicitTriviaFacts: [String] {
        ((trivia?.values ?? []) + (funFacts?.values ?? []))
            .reduce(into: [String]()) { facts, rawFact in
                let fact = rawFact.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fact.isEmpty,
                      !facts.contains(where: {
                          $0.caseInsensitiveCompare(fact) == .orderedSame
                      })
                else { return }
                facts.append(fact)
            }
    }

    public func fillingTrailerMetadata(from fallback: MetaItem) -> MetaItem {
        let needsPoster = poster == nil && fallback.poster != nil
        let needsBackground = background == nil && fallback.background != nil
        let needsDescription = normalizedMetadataValue(description) == nil
            && normalizedMetadataValue(fallback.description) != nil
        let needsReleaseInfo = normalizedMetadataValue(releaseInfo) == nil
            && normalizedMetadataValue(fallback.releaseInfo) != nil
        let needsVideos = (videos?.isEmpty != false)
            && fallback.videos?.isEmpty == false
        let needsTrailer = preferredTrailerURL == nil && fallback.preferredTrailerURL != nil
        let needsCast = actorNames.isEmpty && !fallback.actorNames.isEmpty
        let needsGenres = normalizedMetadataList(genres).isEmpty
            && !normalizedMetadataList(fallback.genres).isEmpty
        let needsRuntime = normalizedMetadataValue(runtime) == nil
            && normalizedMetadataValue(fallback.runtime) != nil
        let needsRating = normalizedMetadataValue(imdbRating) == nil
            && normalizedMetadataValue(fallback.imdbRating) != nil
        let needsDirector = normalizedMetadataList(director).isEmpty
            && !normalizedMetadataList(fallback.director).isEmpty
        let needsWriter = normalizedMetadataList(writer).isEmpty
            && !normalizedMetadataList(fallback.writer).isEmpty
        let needsCountry = normalizedMetadataValue(country) == nil
            && normalizedMetadataValue(fallback.country) != nil
        let needsLanguage = normalizedMetadataValue(language) == nil
            && normalizedMetadataValue(fallback.language) != nil
        let needsCertification = normalizedMetadataValue(certification) == nil
            && normalizedMetadataValue(fallback.certification) != nil
        let needsAwards = normalizedMetadataValue(awards) == nil
            && normalizedMetadataValue(fallback.awards) != nil
        let needsStatus = normalizedMetadataValue(status) == nil
            && normalizedMetadataValue(fallback.status) != nil
        let needsReleased = normalizedMetadataValue(released) == nil
            && normalizedMetadataValue(fallback.released) != nil
        let needsTrivia = normalizedMetadataList(trivia?.values).isEmpty
            && !normalizedMetadataList(fallback.trivia?.values).isEmpty
        let needsFunFacts = normalizedMetadataList(funFacts?.values).isEmpty
            && !normalizedMetadataList(fallback.funFacts?.values).isEmpty
        guard needsPoster || needsBackground || needsDescription || needsReleaseInfo
            || needsVideos || needsTrailer || needsCast || needsGenres || needsRuntime || needsRating
            || needsDirector || needsWriter || needsCountry || needsLanguage
            || needsCertification || needsAwards || needsStatus || needsReleased
            || needsTrivia || needsFunFacts else {
            return self
        }
        return MetaItem(
            id: id,
            type: type,
            name: name,
            poster: needsPoster ? fallback.poster : poster,
            background: needsBackground ? fallback.background : background,
            description: needsDescription ? fallback.description : description,
            releaseInfo: needsReleaseInfo ? fallback.releaseInfo : releaseInfo,
            genres: needsGenres ? fallback.genres : genres,
            cast: needsCast ? fallback.cast : cast,
            actors: needsCast ? fallback.actors : actors,
            runtime: needsRuntime ? fallback.runtime : runtime,
            imdbRating: needsRating ? fallback.imdbRating : imdbRating,
            director: needsDirector ? fallback.director : director,
            writer: needsWriter ? fallback.writer : writer,
            country: needsCountry ? fallback.country : country,
            language: needsLanguage ? fallback.language : language,
            certification: needsCertification ? fallback.certification : certification,
            awards: needsAwards ? fallback.awards : awards,
            status: needsStatus ? fallback.status : status,
            released: needsReleased ? fallback.released : released,
            trivia: needsTrivia ? fallback.trivia?.values : trivia?.values,
            funFacts: needsFunFacts ? fallback.funFacts?.values : funFacts?.values,
            videos: needsVideos ? fallback.videos : videos,
            trailerStreams: needsTrailer ? fallback.trailerStreams : trailerStreams,
            trailers: needsTrailer ? fallback.trailers : trailers
        )
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func normalizedMetadataList(_ values: [String]?) -> [String] {
        (values ?? []).filter { normalizedMetadataValue($0) != nil }
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
    public let overview: String?
    public let released: String?

    public init(
        id: String,
        title: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        thumbnail: URL? = nil,
        overview: String? = nil,
        released: String? = nil
    ) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
        self.released = released
    }
}

public struct PlaybackSkipSegment: Codable, Equatable, Hashable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let type: String
    public let title: String?
    public let confidence: Double?
    public let sampleSize: Int?

    public init(
        start: TimeInterval,
        end: TimeInterval,
        type: String,
        title: String? = nil,
        confidence: Double? = nil,
        sampleSize: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.type = type
        self.title = title
        self.confidence = confidence
        self.sampleSize = sampleSize
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case startTime
        case endTime
        case type
        case title
        case confidence
        case sampleSize
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decodeIfPresent(TimeInterval.self, forKey: .start)
            ?? values.decode(TimeInterval.self, forKey: .startTime)
        end = try values.decodeIfPresent(TimeInterval.self, forKey: .end)
            ?? values.decode(TimeInterval.self, forKey: .endTime)
        type = try values.decode(String.self, forKey: .type)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        sampleSize = try values.decodeIfPresent(Int.self, forKey: .sampleSize)
        if let numeric = try? values.decodeIfPresent(Double.self, forKey: .confidence) {
            confidence = numeric
        } else if let text = try? values.decodeIfPresent(String.self, forKey: .confidence) {
            confidence = Double(text)
        } else {
            confidence = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(type, forKey: .type)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(confidence, forKey: .confidence)
        try values.encodeIfPresent(sampleSize, forKey: .sampleSize)
    }
}

public struct StreamBehaviorHints: Codable, Equatable, Hashable, Sendable {
    public let skipSegments: [PlaybackSkipSegment]?

    public init(skipSegments: [PlaybackSkipSegment]? = nil) {
        self.skipSegments = skipSegments
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
    public let skipSegments: [PlaybackSkipSegment]?
    public let behaviorHints: StreamBehaviorHints?

    public init(
        url: URL?,
        externalUrl: URL?,
        name: String?,
        title: String?,
        description: String?,
        infoHash: String?,
        fileIdx: Int?,
        sources: [String]?,
        skipSegments: [PlaybackSkipSegment]? = nil,
        behaviorHints: StreamBehaviorHints? = nil
    ) {
        self.url = url
        self.externalUrl = externalUrl
        self.name = name
        self.title = title
        self.description = description
        self.infoHash = infoHash
        self.fileIdx = fileIdx
        self.sources = sources
        self.skipSegments = skipSegments
        self.behaviorHints = behaviorHints
    }

    public var id: String {
        [
            url?.absoluteString,
            externalUrl?.absoluteString,
            infoHash,
            fileIdx.map(String.init),
            name,
            title,
        ]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    public var displayName: String {
        title ?? name ?? url?.host ?? externalUrl?.host ?? "Stream"
    }

    public var isDirectlyPlayable: Bool { url != nil }
    public var isTorrent: Bool { infoHash != nil }

    public var introSkipSegment: PlaybackSkipSegment? {
        IntroSkipPolicy.bestValidatedSegment(
            from: (skipSegments ?? []) + (behaviorHints?.skipSegments ?? [])
        )
    }

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
