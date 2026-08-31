import Foundation

public struct PlaybackMediaMetadata: Codable, Equatable, Sendable {
    public let mediaID: String
    public let mediaType: String
    public let mediaTitle: String
    public let posterURL: URL?
    public let episodeID: String?
    public let episodeTitle: String?
    public let season: Int?
    public let episode: Int?
    public let episodeThumbnailURL: URL?

    public init(
        mediaID: String,
        mediaType: String,
        mediaTitle: String,
        posterURL: URL? = nil,
        episodeID: String? = nil,
        episodeTitle: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodeThumbnailURL: URL? = nil
    ) {
        self.mediaID = mediaID
        self.mediaType = mediaType
        self.mediaTitle = mediaTitle
        self.posterURL = posterURL
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.season = season
        self.episode = episode
        self.episodeThumbnailURL = episodeThumbnailURL
    }

    public static func movie(_ item: MetaItem) -> Self {
        Self(
            mediaID: item.id,
            mediaType: item.type,
            mediaTitle: item.name,
            posterURL: item.poster
        )
    }

    public static func episode(series: MetaItem, episode: Video) -> Self {
        Self(
            mediaID: series.id,
            mediaType: series.type,
            mediaTitle: series.name,
            posterURL: series.poster,
            episodeID: episode.id,
            episodeTitle: episode.title,
            season: episode.season,
            episode: episode.episode,
            episodeThumbnailURL: episode.thumbnail
        )
    }
}

public struct PlaybackProgress: Codable, Equatable, Identifiable, Sendable {
    public static let minimumResumePosition: TimeInterval = 10
    public static let completionFraction = 0.95
    public static let creditsRemainingThreshold: TimeInterval = 120
    public static let creditsCompletionFraction = 0.80

    public let contentIdentifier: String
    public let contentTitle: String
    public let stream: Stream
    public let providerName: String?
    public let position: TimeInterval
    public let duration: TimeInterval
    public let updatedAt: Date
    public let mediaMetadata: PlaybackMediaMetadata?

    public var id: String { contentIdentifier }

    public init(
        contentIdentifier: String,
        contentTitle: String,
        stream: Stream,
        providerName: String? = nil,
        position: TimeInterval,
        duration: TimeInterval,
        updatedAt: Date = Date(),
        mediaMetadata: PlaybackMediaMetadata? = nil
    ) {
        self.contentIdentifier = contentIdentifier
        self.contentTitle = contentTitle
        self.stream = stream
        self.providerName = providerName
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.mediaMetadata = mediaMetadata
    }

    public static func shouldSave(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard isRepresentableTimelineValue(position),
              isRepresentableTimelineValue(duration),
              position >= minimumResumePosition
        else { return false }
        guard duration > 0 else { return true }

        let fraction = min(max(position / duration, 0), 1)
        let remaining = max(duration - position, 0)
        return fraction < completionFraction
            && !(fraction >= creditsCompletionFraction
                && remaining <= creditsRemainingThreshold)
    }

    public static func isCompleted(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard isRepresentableTimelineValue(position),
              isRepresentableTimelineValue(duration),
              position >= minimumResumePosition, duration > 0
        else { return false }
        return !shouldSave(position: position, duration: duration)
    }

    public static func isRepresentableTimelineValue(_ value: TimeInterval) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        let nanoseconds = value * 1_000_000_000
        return nanoseconds.isFinite
            && UInt64(exactly: nanoseconds.rounded(.down)) != nil
    }
}

public enum PlaybackTimeFormatter {
    public static func wholeSeconds(
        _ value: TimeInterval,
        rounding rule: FloatingPointRoundingRule = .down
    ) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        return Int(exactly: value.rounded(rule))
    }

    public static func clock(
        _ value: TimeInterval,
        invalidValue: String = "0:00",
        zeroPadMinutes: Bool = false,
        rounding rule: FloatingPointRoundingRule = .down
    ) -> String {
        guard let total = wholeSeconds(value, rounding: rule) else {
            return invalidValue
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : String(minutes)
        let paddedSeconds = seconds < 10 ? "0\(seconds)" : String(seconds)
        if hours > 0 {
            return "\(hours):\(paddedMinutes):\(paddedSeconds)"
        }
        let displayedMinutes = zeroPadMinutes ? paddedMinutes : String(minutes)
        return "\(displayedMinutes):\(paddedSeconds)"
    }
}

public enum ContinueWatchingSelector {
    /// Keeps only the newest unfinished item for each movie or series. A
    /// series with several partially watched episodes therefore occupies one
    /// card and resumes its most recently watched episode.
    public static func latest(
        from progress: [PlaybackProgress],
        limit: Int = 12
    ) -> [PlaybackProgress] {
        guard limit > 0 else { return [] }
        var seenMedia = Set<String>()
        return progress
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seenMedia.insert(groupingIdentifier(for: $0)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    public static func groupingIdentifier(for progress: PlaybackProgress) -> String {
        if let metadata = progress.mediaMetadata {
            return "\(metadata.mediaType):\(metadata.mediaID)"
        }
        if progress.contentIdentifier.hasPrefix("series:"),
           let marker = progress.contentIdentifier.range(of: ":episode:") {
            return String(progress.contentIdentifier[..<marker.lowerBound])
        }
        return progress.contentIdentifier
    }
}

public actor PlaybackProgressStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [PlaybackProgress]?
    private var latestUpdates: [String: Date] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func items() throws -> [PlaybackProgress] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded: [PlaybackProgress]
        do {
            decoded = try decoder.decode([PlaybackProgress].self, from: data)
        } catch {
            try LocalPreferenceRecovery.preserveCorruptFile(fileURL)
            latestUpdates.removeAll()
            try persist([])
            return []
        }
        let sanitized = decoded.compactMap { progress in
            progress.isValidForPersistence ? progress.persistenceSafe : nil
        }
        let current = sanitized.reduce(into: [String: PlaybackProgress]()) { result, progress in
            if result[progress.contentIdentifier]?.updatedAt ?? .distantPast < progress.updatedAt {
                result[progress.contentIdentifier] = progress
            }
        }
        .values
        .sorted { $0.updatedAt > $1.updatedAt }
        cache = current
        latestUpdates = Dictionary(
            uniqueKeysWithValues: current.map { ($0.contentIdentifier, $0.updatedAt) }
        )
        if decoded != sanitized {
            try persist(current)
        }
        return current
    }

    @discardableResult
    public func record(_ progress: PlaybackProgress) throws -> [PlaybackProgress] {
        var current = try items()
        guard !progress.contentIdentifier.isEmpty,
              PlaybackProgress.isRepresentableTimelineValue(progress.position),
              PlaybackProgress.isRepresentableTimelineValue(progress.duration),
              progress.position >= PlaybackProgress.minimumResumePosition
        else { return current }

        if let latest = latestUpdates[progress.contentIdentifier],
           latest > progress.updatedAt {
            return current
        }
        latestUpdates[progress.contentIdentifier] = progress.updatedAt
        current.removeAll { $0.contentIdentifier == progress.contentIdentifier }
        if PlaybackProgress.shouldSave(
            position: progress.position,
            duration: progress.duration
        ) {
            current.append(progress.persistenceSafe)
        }
        current.sort { $0.updatedAt > $1.updatedAt }
        try persist(current)
        return current
    }

    @discardableResult
    public func remove(
        contentIdentifier: String,
        updatedAt: Date = Date()
    ) throws -> [PlaybackProgress] {
        var current = try items()
        if let latest = latestUpdates[contentIdentifier], latest > updatedAt {
            return current
        }
        latestUpdates[contentIdentifier] = updatedAt
        current.removeAll { $0.contentIdentifier == contentIdentifier }
        try persist(current)
        return current
    }

    private func persist(_ items: [PlaybackProgress]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(items.map(\.persistenceSafe)).write(to: fileURL, options: .atomic)
        cache = items.map(\.persistenceSafe)
    }
}

extension PlaybackProgress {
    var isValidForPersistence: Bool {
        !contentIdentifier.isEmpty
            && Self.isRepresentableTimelineValue(position)
            && Self.isRepresentableTimelineValue(duration)
            && position >= Self.minimumResumePosition
    }

    var persistenceSafe: PlaybackProgress {
        PlaybackProgress(
            contentIdentifier: contentIdentifier,
            contentTitle: contentTitle,
            stream: Stream(
                url: nil,
                externalUrl: nil,
                name: stream.name,
                title: stream.title,
                description: nil,
                infoHash: stream.infoHash,
                fileIdx: stream.fileIdx,
                sources: nil,
                skipSegments: stream.skipSegments,
                behaviorHints: stream.behaviorHints
            ),
            providerName: providerName,
            position: position,
            duration: duration,
            updatedAt: updatedAt,
            mediaMetadata: mediaMetadata.map { metadata in
                PlaybackMediaMetadata(
                    mediaID: metadata.mediaID,
                    mediaType: metadata.mediaType,
                    mediaTitle: metadata.mediaTitle,
                    posterURL: metadata.posterURL?.removingPrivateURLComponents,
                    episodeID: metadata.episodeID,
                    episodeTitle: metadata.episodeTitle,
                    season: metadata.season,
                    episode: metadata.episode,
                    episodeThumbnailURL: metadata.episodeThumbnailURL?.removingPrivateURLComponents
                )
            }
        )
    }
}

private extension URL {
    var removingPrivateURLComponents: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }
}
