import Foundation

public struct PlaybackCompletion: Codable, Equatable, Identifiable, Sendable {
    public let contentIdentifier: String
    public let completedAt: Date

    public var id: String { contentIdentifier }

    public init(contentIdentifier: String, completedAt: Date = Date()) {
        self.contentIdentifier = contentIdentifier
        self.completedAt = completedAt
    }
}

public enum EpisodePlaybackIdentity {
    public static func contentIdentifier(seriesID: String, videoID: String) -> String {
        "series:\(seriesID):episode:\(videoID)"
    }

    public static func contentTitle(seriesTitle: String, video: Video) -> String {
        let location: String
        if let season = video.season, let episode = video.episode {
            location = "S\(season) E\(episode)"
        } else if let episode = video.episode {
            location = "Episode \(episode)"
        } else {
            location = "Episode"
        }

        guard let title = video.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return "\(seriesTitle) • \(location)" }
        return "\(seriesTitle) • \(location) • \(title)"
    }
}

public enum EpisodePlaybackCompletionTransition: Equatable, Sendable {
    case noChange
    case markIncomplete
    case markCompleted
}

public enum EpisodePlaybackCompletionPolicy {
    /// Selecting a completed episode is not enough to clear it. Once a replay
    /// has produced meaningful progress, it becomes unfinished again until it
    /// reaches the same completion threshold as a first viewing.
    public static func transition(
        isCompleted: Bool,
        position: TimeInterval,
        duration: TimeInterval
    ) -> EpisodePlaybackCompletionTransition {
        if PlaybackProgress.isCompleted(position: position, duration: duration) {
            return .markCompleted
        }
        if isCompleted,
           PlaybackProgress.shouldSave(position: position, duration: duration) {
            return .markIncomplete
        }
        return .noChange
    }
}

public actor PlaybackCompletionStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [PlaybackCompletion]?
    private var latestUpdates: [String: Date] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func items() throws -> [PlaybackCompletion] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoded: [PlaybackCompletion]
        do {
            decoded = try decoder.decode([PlaybackCompletion].self, from: data)
        } catch {
            try LocalPreferenceRecovery.preserveCorruptFile(fileURL)
            latestUpdates.removeAll()
            try persist([])
            return []
        }
        let current = decoded.reduce(into: [String: PlaybackCompletion]()) {
            result,
            completion in
            if result[completion.contentIdentifier]?.completedAt ?? .distantPast
                < completion.completedAt {
                result[completion.contentIdentifier] = completion
            }
        }
        .values
        .sorted { $0.completedAt > $1.completedAt }
        cache = current
        latestUpdates = Dictionary(
            uniqueKeysWithValues: current.map {
                ($0.contentIdentifier, $0.completedAt)
            }
        )
        return current
    }

    @discardableResult
    public func markCompleted(
        contentIdentifier: String,
        completedAt: Date = Date()
    ) throws -> [PlaybackCompletion] {
        var current = try items()
        guard !contentIdentifier.isEmpty else { return current }
        if let latest = latestUpdates[contentIdentifier], latest > completedAt {
            return current
        }
        latestUpdates[contentIdentifier] = completedAt
        if let existing = current.first(where: {
            $0.contentIdentifier == contentIdentifier
        }), existing.completedAt >= completedAt {
            return current
        }

        current.removeAll { $0.contentIdentifier == contentIdentifier }
        current.append(
            PlaybackCompletion(
                contentIdentifier: contentIdentifier,
                completedAt: completedAt
            )
        )
        current.sort { $0.completedAt > $1.completedAt }
        try persist(current)
        return current
    }

    @discardableResult
    public func markIncomplete(
        contentIdentifier: String,
        updatedAt: Date = Date()
    ) throws -> [PlaybackCompletion] {
        var current = try items()
        guard !contentIdentifier.isEmpty else { return current }
        if let latest = latestUpdates[contentIdentifier], latest > updatedAt {
            return current
        }
        latestUpdates[contentIdentifier] = updatedAt

        let previousCount = current.count
        current.removeAll { $0.contentIdentifier == contentIdentifier }
        guard current.count != previousCount else { return current }
        try persist(current)
        return current
    }

    private func persist(_ items: [PlaybackCompletion]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(items).write(to: fileURL, options: .atomic)
        cache = items
    }
}
