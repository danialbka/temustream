import Foundation

public struct LocalMediaSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let title: String
    public let genres: [String]
    public let actors: [String]

    public init(
        id: String,
        type: String,
        title: String,
        genres: [String] = [],
        actors: [String] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.genres = Self.normalizedValues(genres)
        self.actors = Self.normalizedValues(actors)
    }

    public init(item: MetaItem) {
        self.init(
            id: item.id,
            type: item.type,
            title: item.name,
            genres: item.genres ?? [],
            actors: item.actorNames
        )
    }

    public var identity: LocalMediaIdentity {
        LocalMediaIdentity(id: id, type: type)
    }

    private static func normalizedValues(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !result.contains(where: {
                      $0.caseInsensitiveCompare(value) == .orderedSame
                  })
            else { return }
            result.append(value)
        }
    }
}

public struct LocalMediaIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let type: String

    public init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    public init(item: MetaItem) {
        self.init(id: item.id, type: item.type)
    }
}

public enum MediaReaction: String, CaseIterable, Codable, Equatable, Sendable {
    case dislike
    case like
    case love
}

public struct MediaRating: Codable, Equatable, Identifiable, Sendable {
    public let media: LocalMediaSnapshot
    public let reaction: MediaReaction
    public let updatedAt: Date

    public var id: LocalMediaIdentity { media.identity }

    public init(
        media: LocalMediaSnapshot,
        reaction: MediaReaction,
        updatedAt: Date = Date()
    ) {
        self.media = media
        self.reaction = reaction
        self.updatedAt = updatedAt
    }
}

public enum RecommendationActivityKind: String, Codable, Equatable, Sendable {
    case addedToLibrary
    case watched
    case completed
}

public struct RecommendationActivity: Codable, Equatable, Sendable {
    public let media: LocalMediaSnapshot
    public let kind: RecommendationActivityKind
    public let occurredAt: Date

    public init(
        media: LocalMediaSnapshot,
        kind: RecommendationActivityKind,
        occurredAt: Date = Date()
    ) {
        self.media = media
        self.kind = kind
        self.occurredAt = occurredAt
    }

    public init(
        item: MetaItem,
        kind: RecommendationActivityKind,
        occurredAt: Date = Date()
    ) {
        self.init(
            media: LocalMediaSnapshot(item: item),
            kind: kind,
            occurredAt: occurredAt
        )
    }
}

public struct RecommendationImpression: Codable, Equatable, Identifiable, Sendable {
    public let mediaID: LocalMediaIdentity
    public let firstShownAt: Date
    public let lastShownAt: Date
    public let showCount: Int

    public var id: LocalMediaIdentity { mediaID }

    public init(
        mediaID: LocalMediaIdentity,
        firstShownAt: Date,
        lastShownAt: Date,
        showCount: Int
    ) {
        self.mediaID = mediaID
        self.firstShownAt = firstShownAt
        self.lastShownAt = lastShownAt
        self.showCount = max(showCount, 1)
    }

    private enum CodingKeys: String, CodingKey {
        case mediaID
        case firstShownAt
        case lastShownAt
        case showCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mediaID: try container.decode(LocalMediaIdentity.self, forKey: .mediaID),
            firstShownAt: try container.decode(Date.self, forKey: .firstShownAt),
            lastShownAt: try container.decode(Date.self, forKey: .lastShownAt),
            showCount: try container.decode(Int.self, forKey: .showCount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaID, forKey: .mediaID)
        try container.encode(firstShownAt, forKey: .firstShownAt)
        try container.encode(lastShownAt, forKey: .lastShownAt)
        try container.encode(showCount, forKey: .showCount)
    }
}

public struct LocalRecommendation: Equatable, Identifiable, Sendable {
    public let item: MetaItem
    public let score: Double
    public let reasons: [String]

    public var id: LocalMediaIdentity { LocalMediaIdentity(item: item) }

    public init(item: MetaItem, score: Double, reasons: [String]) {
        self.item = item
        self.score = score
        self.reasons = reasons
    }
}

/// Publishes a large ranked recommendation set in stable, deduplicated windows.
/// Newly fetched provider results are appended behind the already presented
/// order so reaching the end of a shelf never makes visible cards jump around.
public struct LocalRecommendationPager: Sendable {
    public let pageSize: Int
    public private(set) var rankedRecommendations: [LocalRecommendation] = []
    public private(set) var visibleCount = 0

    public init(pageSize: Int = 12) {
        self.pageSize = max(pageSize, 1)
    }

    public var visibleRecommendations: [LocalRecommendation] {
        Array(rankedRecommendations.prefix(visibleCount))
    }

    public var canRevealMore: Bool {
        visibleCount < rankedRecommendations.count
    }

    public mutating func reset(with recommendations: [LocalRecommendation]) {
        rankedRecommendations = Self.unique(recommendations)
        visibleCount = min(pageSize, rankedRecommendations.count)
    }

    @discardableResult
    public mutating func appendRanked(
        _ recommendations: [LocalRecommendation]
    ) -> Int {
        var seen = Set(rankedRecommendations.map(\.id))
        let additions = recommendations.filter { seen.insert($0.id).inserted }
        rankedRecommendations.append(contentsOf: additions)
        return additions.count
    }

    @discardableResult
    public mutating func revealNextPage() -> [LocalRecommendation] {
        visibleCount = min(visibleCount + pageSize, rankedRecommendations.count)
        return visibleRecommendations
    }

    public mutating func clear() {
        rankedRecommendations.removeAll(keepingCapacity: true)
        visibleCount = 0
    }

    private static func unique(
        _ recommendations: [LocalRecommendation]
    ) -> [LocalRecommendation] {
        var seen = Set<LocalMediaIdentity>()
        return recommendations.filter { seen.insert($0.id).inserted }
    }
}

public actor MediaRatingStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cache: [MediaRating]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = Self.makeEncoder()
        decoder = Self.makeDecoder()
    }

    public func items() throws -> [MediaRating] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let decoded = try decoder.decode(
                [MediaRating].self,
                from: data
            )
            let current = Self.latestRatings(from: decoded)
            cache = current
            return current
        } catch {
            try LocalPreferenceRecovery.preserveCorruptFile(fileURL)
            try persist([])
            return []
        }
    }

    public func reaction(for item: MetaItem) throws -> MediaReaction? {
        try items().first { $0.id == LocalMediaIdentity(item: item) }?.reaction
    }

    @discardableResult
    public func set(
        _ reaction: MediaReaction?,
        for item: MetaItem,
        at date: Date = Date()
    ) throws -> [MediaRating] {
        var current = try items()
        let identity = LocalMediaIdentity(item: item)
        if let existing = current.first(where: { $0.id == identity }),
           existing.updatedAt > date {
            return current
        }
        current.removeAll { $0.id == identity }
        if let reaction {
            current.append(
                MediaRating(
                    media: LocalMediaSnapshot(item: item),
                    reaction: reaction,
                    updatedAt: date
                )
            )
        }
        current.sort(by: Self.ratingOrder)
        try persist(current)
        return current
    }

    @discardableResult
    public func reset() throws -> [MediaRating] {
        try persist([])
        return []
    }

    private func persist(_ ratings: [MediaRating]) throws {
        try LocalPreferenceRecovery.persist(
            ratings,
            to: fileURL,
            encoder: encoder
        )
        cache = ratings
    }

    private static func latestRatings(from ratings: [MediaRating]) -> [MediaRating] {
        var latest: [LocalMediaIdentity: MediaRating] = [:]
        for rating in ratings {
            if latest[rating.id]?.updatedAt ?? .distantPast <= rating.updatedAt {
                latest[rating.id] = rating
            }
        }
        return latest.values.sorted(by: ratingOrder)
    }

    private static func ratingOrder(_ lhs: MediaRating, _ rhs: MediaRating) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.media.type != rhs.media.type { return lhs.media.type < rhs.media.type }
        return lhs.media.id < rhs.media.id
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public actor RecommendationHistoryStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cache: [RecommendationImpression]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func items() throws -> [RecommendationImpression] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let decoded = try decoder.decode(
                [RecommendationImpression].self,
                from: data
            )
            let current = Self.mergedImpressions(decoded)
            cache = current
            return current
        } catch {
            try LocalPreferenceRecovery.preserveCorruptFile(fileURL)
            try persist([])
            return []
        }
    }

    @discardableResult
    public func record(
        _ recommendations: [LocalRecommendation],
        shownAt: Date = Date()
    ) throws -> [RecommendationImpression] {
        var current = try items()
        for recommendation in recommendations {
            let identity = recommendation.id
            if let index = current.firstIndex(where: { $0.id == identity }) {
                let existing = current[index]
                guard existing.lastShownAt <= shownAt else { continue }
                current[index] = RecommendationImpression(
                    mediaID: identity,
                    firstShownAt: existing.firstShownAt,
                    lastShownAt: shownAt,
                    showCount: Self.saturatedShowCountSum(existing.showCount, 1)
                )
            } else {
                current.append(
                    RecommendationImpression(
                        mediaID: identity,
                        firstShownAt: shownAt,
                        lastShownAt: shownAt,
                        showCount: 1
                    )
                )
            }
        }
        current.sort(by: Self.impressionOrder)
        try persist(current)
        return current
    }

    @discardableResult
    public func reset() throws -> [RecommendationImpression] {
        try persist([])
        return []
    }

    private func persist(_ history: [RecommendationImpression]) throws {
        try LocalPreferenceRecovery.persist(
            history,
            to: fileURL,
            encoder: encoder
        )
        cache = history
    }

    private static func mergedImpressions(
        _ impressions: [RecommendationImpression]
    ) -> [RecommendationImpression] {
        var merged: [LocalMediaIdentity: RecommendationImpression] = [:]
        for impression in impressions {
            if let existing = merged[impression.id] {
                merged[impression.id] = RecommendationImpression(
                    mediaID: impression.id,
                    firstShownAt: min(existing.firstShownAt, impression.firstShownAt),
                    lastShownAt: max(existing.lastShownAt, impression.lastShownAt),
                    showCount: saturatedShowCountSum(
                        existing.showCount,
                        impression.showCount
                    )
                )
            } else {
                merged[impression.id] = impression
            }
        }
        return merged.values.sorted(by: impressionOrder)
    }

    private static func saturatedShowCountSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = max(lhs, 1).addingReportingOverflow(max(rhs, 1))
        return overflow ? .max : sum
    }

    private static func impressionOrder(
        _ lhs: RecommendationImpression,
        _ rhs: RecommendationImpression
    ) -> Bool {
        if lhs.lastShownAt != rhs.lastShownAt {
            return lhs.lastShownAt > rhs.lastShownAt
        }
        if lhs.mediaID.type != rhs.mediaID.type {
            return lhs.mediaID.type < rhs.mediaID.type
        }
        return lhs.mediaID.id < rhs.mediaID.id
    }
}

public enum LocalRecommendationEngine {
    private struct Affinity {
        var displayName: String
        var score: Double
        var strongestSource: String
        var sourceWeight: Double
    }

    private struct ScoredCandidate {
        var index: Int
        var recommendation: LocalRecommendation
    }

    public static func recommend(
        candidates: [MetaItem],
        activity: [RecommendationActivity],
        ratings: [MediaRating],
        impressions: [RecommendationImpression] = [],
        limit: Int = 12
    ) -> [LocalRecommendation] {
        guard limit > 0 else { return [] }

        let ratingsByID = ratings.reduce(into: [LocalMediaIdentity: MediaRating]()) {
            latest, rating in
            if latest[rating.id]?.updatedAt ?? .distantPast <= rating.updatedAt {
                latest[rating.id] = rating
            }
        }
        let excludedIDs = Set(activity.map { $0.media.identity })
            .union(ratingsByID.keys)
        let impressionsByID = impressions.reduce(
            into: [LocalMediaIdentity: RecommendationImpression]()
        ) { latest, impression in
            if latest[impression.id]?.lastShownAt ?? .distantPast
                <= impression.lastShownAt {
                latest[impression.id] = impression
            }
        }

        var genreAffinity: [String: Affinity] = [:]
        var actorAffinity: [String: Affinity] = [:]

        for signal in activity.sorted(by: activityOrder) {
            let weights = weights(for: signal.kind)
            add(
                media: signal.media,
                source: signal.media.title,
                genreWeight: weights.genre,
                actorWeight: weights.actor,
                genreAffinity: &genreAffinity,
                actorAffinity: &actorAffinity
            )
        }
        for rating in ratings.sorted(by: ratingOrder) {
            let weights = weights(for: rating.reaction)
            add(
                media: rating.media,
                source: rating.media.title,
                genreWeight: weights.genre,
                actorWeight: weights.actor,
                genreAffinity: &genreAffinity,
                actorAffinity: &actorAffinity
            )
        }

        var seen = Set<LocalMediaIdentity>()
        let scored = candidates.enumerated().compactMap { index, item -> ScoredCandidate? in
            let identity = LocalMediaIdentity(item: item)
            guard seen.insert(identity).inserted,
                  !excludedIDs.contains(identity),
                  ratingsByID[identity]?.reaction != .dislike
            else { return nil }

            let genreMatches = matches(
                values: item.genres ?? [],
                affinity: genreAffinity
            )
            let actorMatches = matches(
                values: item.actorNames,
                affinity: actorAffinity
            )
            let genreScore = genreMatches.reduce(0) { $0 + $1.affinity.score }
            let actorScore = actorMatches.reduce(0) { $0 + $1.affinity.score }
            let repetitionPenalty = min(
                Double(impressionsByID[identity]?.showCount ?? 0) * 0.5,
                3
            )
            let score = genreScore + actorScore - repetitionPenalty

            var reasons: [String] = []
            if let genre = genreMatches
                .filter({ $0.affinity.score > 0 })
                .max(by: matchOrder) {
                reasons.append(
                    "Because you enjoyed \(genre.affinity.strongestSource)'s \(genre.affinity.displayName) stories"
                )
            }
            if let actor = actorMatches
                .filter({ $0.affinity.score > 0 })
                .max(by: matchOrder),
               reasons.count < 2 {
                reasons.append("Featuring \(actor.affinity.displayName)")
            }
            if reasons.isEmpty {
                if let genre = item.genres?.first {
                    reasons.append("More \(genre) from this catalog")
                } else {
                    reasons.append("More from this catalog")
                }
            }

            return ScoredCandidate(
                index: index,
                recommendation: LocalRecommendation(
                    item: item,
                    score: score,
                    reasons: reasons
                )
            )
        }

        return scored.sorted { lhs, rhs in
            if lhs.recommendation.score != rhs.recommendation.score {
                return lhs.recommendation.score > rhs.recommendation.score
            }
            return lhs.index < rhs.index
        }
        .prefix(limit)
        .map(\.recommendation)
    }

    private static func weights(
        for kind: RecommendationActivityKind
    ) -> (genre: Double, actor: Double) {
        switch kind {
        case .addedToLibrary: return (1.5, 1)
        case .watched: return (2.5, 2)
        case .completed: return (3.5, 2.5)
        }
    }

    private static func weights(
        for reaction: MediaReaction
    ) -> (genre: Double, actor: Double) {
        switch reaction {
        case .dislike: return (-2.5, -1.5)
        case .like: return (4, 3)
        case .love: return (7, 5)
        }
    }

    private static func add(
        media: LocalMediaSnapshot,
        source: String,
        genreWeight: Double,
        actorWeight: Double,
        genreAffinity: inout [String: Affinity],
        actorAffinity: inout [String: Affinity]
    ) {
        for genre in media.genres {
            add(
                value: genre,
                score: genreWeight,
                source: source,
                to: &genreAffinity
            )
        }
        for actor in media.actors {
            add(
                value: actor,
                score: actorWeight,
                source: source,
                to: &actorAffinity
            )
        }
    }

    private static func add(
        value: String,
        score: Double,
        source: String,
        to affinity: inout [String: Affinity]
    ) {
        let key = normalizedKey(value)
        guard !key.isEmpty else { return }
        if var current = affinity[key] {
            current.score += score
            if score > current.sourceWeight {
                current.strongestSource = source
                current.sourceWeight = score
            }
            affinity[key] = current
        } else {
            affinity[key] = Affinity(
                displayName: value,
                score: score,
                strongestSource: source,
                sourceWeight: score
            )
        }
    }

    private static func matches(
        values: [String],
        affinity: [String: Affinity]
    ) -> [(value: String, affinity: Affinity)] {
        values.compactMap { value in
            guard let match = affinity[normalizedKey(value)] else { return nil }
            return (value, match)
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func activityOrder(
        _ lhs: RecommendationActivity,
        _ rhs: RecommendationActivity
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.media.type != rhs.media.type { return lhs.media.type < rhs.media.type }
        return lhs.media.id < rhs.media.id
    }

    private static func ratingOrder(_ lhs: MediaRating, _ rhs: MediaRating) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        if lhs.media.type != rhs.media.type { return lhs.media.type < rhs.media.type }
        return lhs.media.id < rhs.media.id
    }

    private static func matchOrder(
        _ lhs: (value: String, affinity: Affinity),
        _ rhs: (value: String, affinity: Affinity)
    ) -> Bool {
        if lhs.affinity.score != rhs.affinity.score {
            return lhs.affinity.score < rhs.affinity.score
        }
        return lhs.value > rhs.value
    }
}

enum LocalPreferenceRecovery {
    static func persist<Value: Encodable>(
        _ value: Value,
        to fileURL: URL,
        encoder: JSONEncoder
    ) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }

    static func preserveCorruptFile(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let recoveryURL = fileURL.deletingPathExtension().appendingPathExtension(
            "corrupt-\(UUID().uuidString).json"
        )
        try FileManager.default.moveItem(at: fileURL, to: recoveryURL)
    }
}
