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

public actor PlaybackCompletionStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [PlaybackCompletion]?

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

        let decoded = try decoder.decode(
            [PlaybackCompletion].self,
            from: Data(contentsOf: fileURL)
        )
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
        return current
    }

    @discardableResult
    public func markCompleted(
        contentIdentifier: String,
        completedAt: Date = Date()
    ) throws -> [PlaybackCompletion] {
        var current = try items()
        guard !contentIdentifier.isEmpty else { return current }
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

    private func persist(_ items: [PlaybackCompletion]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(items).write(to: fileURL, options: .atomic)
        cache = items
    }
}
