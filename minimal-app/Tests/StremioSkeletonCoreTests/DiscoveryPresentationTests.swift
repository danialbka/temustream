import Foundation
import Testing
@testable import StremioSkeletonCore

struct DiscoveryPresentationTests {
    @Test func shelfDeduplicationIsStableAndCanSpanShelves() {
        let first = item("1", name: "First", genres: ["Drama"])
        let duplicate = item("1", name: "Duplicate", genres: ["Drama"])
        let second = item("2", name: "Second", genres: ["Comedy"])

        let result = DiscoveryShelfBuilder.deduplicated(
            [
                DiscoveryShelf(id: "a", title: "A", items: [first, duplicate]),
                DiscoveryShelf(id: "b", title: "B", items: [duplicate, second]),
            ],
            globally: true
        )

        #expect(result.map(\.id) == ["a", "b"])
        #expect(result[0].items.map(\.name) == ["First"])
        #expect(result[1].items.map(\.name) == ["Second"])
    }

    @Test func genreShelvesAreDeterministicDiverseAndRespectExclusions() {
        let candidates = [
            item("1", genres: ["Drama", "Mystery"]),
            item("2", genres: ["Drama"]),
            item("3", genres: ["Drama", "Mystery"]),
            item("4", genres: ["Mystery"]),
            item("5", genres: ["Comedy"]),
            item("6", genres: ["Comedy"]),
            item("7", genres: ["Comedy"]),
        ]

        let shelves = DiscoveryShelfBuilder.genreShelves(
            from: candidates,
            excluding: [MediaIdentity(candidates[0])],
            minimumItems: 2
        )

        #expect(shelves.map(\.id) == ["genre:comedy", "genre:drama"])
        let identities = shelves.flatMap(\.items).map(MediaIdentity.init)
        #expect(Set(identities).count == identities.count)
        #expect(!identities.contains(MediaIdentity(candidates[0])))
    }

    @Test func relatedTitlesRequireAndRankMetadataOverlap() {
        let target = item(
            "target",
            genres: ["Drama", "Mystery"],
            cast: ["A. Actor"]
        )
        let castMatch = item("cast", genres: ["Comedy"], cast: ["A. Actor"])
        let genreMatch = item("genre", genres: ["Drama"])
        let noMatch = item("none", genres: ["Animation"])

        let result = DiscoveryShelfBuilder.relatedItems(
            to: target,
            candidates: [genreMatch, noMatch, castMatch, target]
        )

        #expect(result.map(\.id) == ["cast", "genre"])
    }

    @Test func recentItemsUseReleaseYearAndStableProviderOrder() {
        let undated = item("undated")
        let older = item("older", releaseInfo: "2022")
        let newestFirst = item("new-a", releaseInfo: "2026-03-10")
        let newestSecond = item("new-b", releaseInfo: "2026–")
        let duplicate = item("new-a", releaseInfo: "2099")

        let result = DiscoveryShelfBuilder.recentItems(
            from: [undated, older, newestFirst, newestSecond, duplicate],
            limit: 3
        )

        #expect(result.map(\.id) == ["new-a", "new-b", "older"])
    }

    @Test func localSearchMatchesTitlesPeopleAndGenresWithinType() {
        let title = item("title", name: "The Great Escape", genres: ["Drama"])
        let actor = item("actor", name: "Elsewhere", cast: ["José Alvarez"])
        let genre = item("genre", name: "Other", genres: ["Science Fiction"])
        let series = MetaItem(
            id: "series",
            type: "series",
            name: "The Great Series",
            genres: ["Drama"]
        )

        #expect(
            DiscoveryShelfBuilder.matchingItems(
                [genre, actor, series, title],
                query: "great",
                mediaType: "movie"
            ).map(\.id) == ["title"]
        )
        #expect(
            DiscoveryShelfBuilder.matchingItems(
                [genre, actor, title],
                query: "jose"
            ).map(\.id) == ["actor"]
        )
        #expect(
            DiscoveryShelfBuilder.matchingItems(
                [genre, actor, title],
                query: "science"
            ).map(\.id) == ["genre"]
        )
    }

    @Test func recentQueriesAreBoundedDeduplicatedAndProfileScoped() {
        let suite = "DiscoveryPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSearchStore(defaults: defaults, limit: 3)

        store.record("  Bunny  ", profileID: "one")
        store.record("Drama", profileID: "one")
        store.record("bunny", profileID: "one")
        store.record("Series", profileID: "one")
        store.record("Movies", profileID: "one")
        store.record("Separate", profileID: "two")

        #expect(store.queries(profileID: "one") == ["Movies", "Series", "bunny"])
        #expect(store.queries(profileID: "two") == ["Separate"])
        store.clear(profileID: "one")
        #expect(store.queries(profileID: "one").isEmpty)
        #expect(store.queries(profileID: "two") == ["Separate"])
    }

    @Test func richMetadataDecodesAndFillsOnlyMissingValues() throws {
        let json = Data(
            #"{"id":"tt1","type":"movie","name":"Fixture","runtime":"142 min","imdbRating":"9.3","director":["Director"],"writer":["Writer"],"country":"United States","language":"English","certification":"PG-13","awards":"Won 2 awards.","status":"Released","released":"2024-06-03T00:00:00.000Z","trivia":["Provider fact."]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(MetaItem.self, from: json)
        #expect(decoded.runtime == "142 min")
        #expect(decoded.imdbRating == "9.3")
        #expect(decoded.director == ["Director"])
        #expect(decoded.writer == ["Writer"])
        #expect(decoded.awards == "Won 2 awards.")
        #expect(decoded.explicitTriviaFacts == ["Provider fact."])

        let sparse = MetaItem(id: "tt1", type: "movie", name: "Fixture", runtime: "90 min")
        let merged = sparse.fillingTrailerMetadata(from: decoded)
        #expect(merged.runtime == "90 min")
        #expect(merged.imdbRating == "9.3")
        #expect(merged.director == ["Director"])
        #expect(merged.country == "United States")
        #expect(merged.awards == "Won 2 awards.")
        #expect(merged.released == "2024-06-03T00:00:00.000Z")
        #expect(merged.explicitTriviaFacts == ["Provider fact."])
    }

    private func item(
        _ id: String,
        name: String? = nil,
        genres: [String] = [],
        cast: [String] = [],
        releaseInfo: String? = nil
    ) -> MetaItem {
        MetaItem(
            id: id,
            type: "movie",
            name: name ?? id,
            releaseInfo: releaseInfo,
            genres: genres,
            cast: cast
        )
    }
}
