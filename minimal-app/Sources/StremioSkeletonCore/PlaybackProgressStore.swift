import Foundation

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

    public var id: String { contentIdentifier }

    public init(
        contentIdentifier: String,
        contentTitle: String,
        stream: Stream,
        providerName: String? = nil,
        position: TimeInterval,
        duration: TimeInterval,
        updatedAt: Date = Date()
    ) {
        self.contentIdentifier = contentIdentifier
        self.contentTitle = contentTitle
        self.stream = stream
        self.providerName = providerName
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public static func shouldSave(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard position.isFinite, duration.isFinite,
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
        guard position.isFinite, duration.isFinite,
              position >= minimumResumePosition, duration > 0
        else { return false }
        return !shouldSave(position: position, duration: duration)
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
        let decoded = try decoder.decode(
            [PlaybackProgress].self,
            from: Data(contentsOf: fileURL)
        )
        let current = decoded.reduce(into: [String: PlaybackProgress]()) { result, progress in
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
        return current
    }

    @discardableResult
    public func record(_ progress: PlaybackProgress) throws -> [PlaybackProgress] {
        var current = try items()
        guard !progress.contentIdentifier.isEmpty,
              progress.position.isFinite,
              progress.duration.isFinite,
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
            current.append(progress)
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
        try encoder.encode(items).write(to: fileURL, options: .atomic)
        cache = items
    }
}
