import Foundation

/// A stable identity used to remove duplicate media without conflating a movie
/// and series that happen to share a provider identifier.
public struct MediaIdentity: Hashable, Sendable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(_ item: MetaItem) {
        self.init(type: item.type, id: item.id)
    }
}

/// Presentation-ready catalog content. Keeping this value in the core lets the
/// app publish complete shelf snapshots instead of rebuilding them on every
/// SwiftUI render.
public struct DiscoveryShelf: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let items: [MetaItem]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        items: [MetaItem]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

public enum DiscoveryShelfBuilder {
    /// Removes duplicates deterministically while preserving the provider's
    /// shelf and item ordering. Global deduplication is useful for independent
    /// recommendation rows; provider-defined rows can opt into per-row only.
    public static func deduplicated(
        _ shelves: [DiscoveryShelf],
        globally: Bool
    ) -> [DiscoveryShelf] {
        var globalIdentities = Set<MediaIdentity>()

        return shelves.compactMap { shelf in
            var localIdentities = Set<MediaIdentity>()
            let items = shelf.items.filter { item in
                let identity = MediaIdentity(item)
                guard localIdentities.insert(identity).inserted else { return false }
                guard !globally || globalIdentities.insert(identity).inserted else {
                    return false
                }
                return true
            }
            guard !items.isEmpty else { return nil }
            return DiscoveryShelf(
                id: shelf.id,
                title: shelf.title,
                subtitle: shelf.subtitle,
                items: items
            )
        }
    }

    /// Builds diverse, non-overlapping genre rows from already loaded metadata.
    /// Genres with the broadest useful selection are emitted first, with stable
    /// alphabetical tie-breaking so the home page does not reshuffle on rerender.
    public static func genreShelves(
        from candidates: [MetaItem],
        excluding excluded: Set<MediaIdentity> = [],
        minimumItems: Int = 3,
        maximumShelves: Int = 4,
        maximumItemsPerShelf: Int = 20
    ) -> [DiscoveryShelf] {
        guard minimumItems > 0, maximumShelves > 0, maximumItemsPerShelf > 0 else {
            return []
        }

        var uniqueCandidates: [MetaItem] = []
        var seenCandidates = excluded
        for item in candidates where seenCandidates.insert(MediaIdentity(item)).inserted {
            uniqueCandidates.append(item)
        }

        var itemsByGenre: [String: [MetaItem]] = [:]
        var displayNames: [String: String] = [:]
        for item in uniqueCandidates {
            var seenItemGenres = Set<String>()
            for rawGenre in item.genres ?? [] {
                let displayName = rawGenre.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = displayName.lowercased()
                guard !displayName.isEmpty, seenItemGenres.insert(key).inserted else { continue }
                displayNames[key] = displayNames[key] ?? displayName
                itemsByGenre[key, default: []].append(item)
            }
        }

        let rankedGenres = itemsByGenre.keys
            .filter { (itemsByGenre[$0]?.count ?? 0) >= minimumItems }
            .sorted { lhs, rhs in
                let lhsCount = itemsByGenre[lhs]?.count ?? 0
                let rhsCount = itemsByGenre[rhs]?.count ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        var assigned = Set<MediaIdentity>()
        var shelves: [DiscoveryShelf] = []
        for genre in rankedGenres {
            let items = (itemsByGenre[genre] ?? []).filter {
                !assigned.contains(MediaIdentity($0))
            }
            guard items.count >= minimumItems else { continue }
            let selected = Array(items.prefix(maximumItemsPerShelf))
            assigned.formUnion(selected.map(MediaIdentity.init))
            let displayName = displayNames[genre] ?? genre.capitalized
            shelves.append(
                DiscoveryShelf(
                    id: "genre:\(genre)",
                    title: displayName,
                    subtitle: "Because you browse \(displayName)",
                    items: selected
                )
            )
            if shelves.count == maximumShelves { break }
        }
        return shelves
    }

    /// Returns the newest dated titles while preserving provider order for
    /// ties. Add-ons commonly send a year, an open-ended year, or a full date,
    /// so release metadata is intentionally interpreted as a year hint.
    public static func recentItems(
        from candidates: [MetaItem],
        limit: Int = 20
    ) -> [MetaItem] {
        guard limit > 0 else { return [] }
        var seen = Set<MediaIdentity>()
        return candidates.enumerated().compactMap { index, item -> RecentRank? in
            guard seen.insert(MediaIdentity(item)).inserted,
                  let year = releaseYear(in: item.releaseInfo)
            else { return nil }
            return RecentRank(item: item, year: year, originalIndex: index)
        }
        .sorted { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            return lhs.originalIndex < rhs.originalIndex
        }
        .prefix(limit)
        .map(\.item)
    }

    /// Searches already loaded metadata as a fast, private complement to
    /// provider search. This is what makes actor, director, writer, and genre
    /// queries useful even when an add-on only implements title search.
    public static func matchingItems(
        _ candidates: [MetaItem],
        query: String,
        mediaType: String? = nil,
        limit: Int = 40
    ) -> [MetaItem] {
        let needle = normalizedSearchText(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let requestedType = mediaType.map(normalizedSearchText)
        var seen = Set<MediaIdentity>()

        return candidates.enumerated().compactMap { index, item -> SearchRank? in
            guard seen.insert(MediaIdentity(item)).inserted else { return nil }
            if let requestedType,
               normalizedSearchText(item.type) != requestedType {
                return nil
            }

            let name = normalizedSearchText(item.name)
            let people = (item.actorNames + (item.director ?? []) + (item.writer ?? []))
                .map(normalizedSearchText)
            let genres = (item.genres ?? []).map(normalizedSearchText)
            let score: Int
            if name == needle {
                score = 0
            } else if name.hasPrefix(needle) {
                score = 1
            } else if name.contains(needle) {
                score = 2
            } else if people.contains(where: { $0.contains(needle) }) {
                score = 3
            } else if genres.contains(where: { $0.contains(needle) }) {
                score = 4
            } else {
                return nil
            }
            return SearchRank(item: item, score: score, originalIndex: index)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.originalIndex < rhs.originalIndex
        }
        .prefix(limit)
        .map(\.item)
    }

    /// Ranks only supplied candidates. A result must share at least one genre or
    /// cast member, so the recommendation remains explainable and never invents
    /// a relationship unsupported by metadata.
    public static func relatedItems(
        to item: MetaItem,
        candidates: [MetaItem],
        limit: Int = 12
    ) -> [MetaItem] {
        guard limit > 0 else { return [] }
        let targetGenres = normalizedSet(item.genres ?? [])
        let targetCast = normalizedSet(item.actorNames)
        var seen = Set<MediaIdentity>([MediaIdentity(item)])

        return candidates.enumerated().compactMap { index, candidate -> RelatedRank? in
            guard seen.insert(MediaIdentity(candidate)).inserted else { return nil }
            let sharedGenres = targetGenres.intersection(normalizedSet(candidate.genres ?? [])).count
            let sharedCast = targetCast.intersection(normalizedSet(candidate.actorNames)).count
            guard sharedGenres > 0 || sharedCast > 0 else { return nil }

            let sameTypeBonus = candidate.type.caseInsensitiveCompare(item.type) == .orderedSame ? 1 : 0
            return RelatedRank(
                item: candidate,
                score: sharedCast * 3 + sharedGenres * 2 + sameTypeBonus,
                originalIndex: index
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.originalIndex != rhs.originalIndex {
                return lhs.originalIndex < rhs.originalIndex
            }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
        .prefix(limit)
        .map(\.item)
    }

    private static func normalizedSet(_ values: [String]) -> Set<String> {
        Set(values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.isEmpty ? nil : value
        })
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func releaseYear(in value: String?) -> Int? {
        guard let value else { return nil }
        return value
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
            .filter { (1888...2100).contains($0) }
            .max()
    }

    private struct RecentRank {
        let item: MetaItem
        let year: Int
        let originalIndex: Int
    }

    private struct SearchRank {
        let item: MetaItem
        let score: Int
        let originalIndex: Int
    }

    private struct RelatedRank {
        let item: MetaItem
        let score: Int
        let originalIndex: Int
    }
}

/// Persists intentional search submissions separately for every viewing
/// profile. Values are bounded and normalized to avoid an ever-growing defaults
/// payload or visually duplicated queries.
public struct RecentSearchStore {
    public static let defaultLimit = 8

    private let defaults: UserDefaults
    private let namespace: String
    private let limit: Int

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = "discovery.recent-searches",
        limit: Int = RecentSearchStore.defaultLimit
    ) {
        self.defaults = defaults
        self.namespace = namespace
        self.limit = max(1, limit)
    }

    public func queries(profileID: String) -> [String] {
        Array((defaults.stringArray(forKey: key(profileID: profileID)) ?? []).prefix(limit))
    }

    public func record(_ query: String, profileID: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let remaining = queries(profileID: profileID).filter {
            $0.caseInsensitiveCompare(normalized) != .orderedSame
        }
        defaults.set(
            Array(([normalized] + remaining).prefix(limit)),
            forKey: key(profileID: profileID)
        )
    }

    public func clear(profileID: String) {
        defaults.removeObject(forKey: key(profileID: profileID))
    }

    private func key(profileID: String) -> String {
        let data = Data(profileID.utf8)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(namespace).\(encoded.isEmpty ? "default" : encoded)"
    }
}
