import Foundation
import XCTest
@testable import StremioSkeletonCore

final class LocalRecommendationsTests: XCTestCase {
    func testRatingsPersistAndRemainIsolatedPerProfileFile() async throws {
        let directory = temporaryDirectory()
        let firstURL = directory.appendingPathComponent("first/media-ratings.json")
        let secondURL = directory.appendingPathComponent("second/media-ratings.json")
        let item = media(
            id: "tt1",
            name: "Moon Rabbit",
            genres: ["Science Fiction"],
            actors: ["Ada Star"]
        )

        _ = try await MediaRatingStore(fileURL: firstURL).set(
            .love,
            for: item,
            at: date(1)
        )

        let first = try await MediaRatingStore(fileURL: firstURL).items()
        let second = try await MediaRatingStore(fileURL: secondURL).items()
        XCTAssertEqual(first.first?.reaction, .love)
        XCTAssertEqual(first.first?.media.genres, ["Science Fiction"])
        XCTAssertEqual(first.first?.media.actors, ["Ada Star"])
        XCTAssertTrue(second.isEmpty)
    }

    func testRatingCanChangeAndBeRemovedButOlderUpdateCannotWin() async throws {
        let store = MediaRatingStore(
            fileURL: temporaryDirectory().appendingPathComponent("ratings.json")
        )
        let item = media(id: "tt1", name: "Movie")

        _ = try await store.set(.like, for: item, at: date(2))
        let older = try await store.set(.dislike, for: item, at: date(1))
        XCTAssertEqual(older.first?.reaction, .like)

        _ = try await store.set(.love, for: item, at: date(3))
        let currentReaction = try await store.reaction(for: item)
        XCTAssertEqual(currentReaction, .love)
        let removed = try await store.set(nil, for: item, at: date(4))
        XCTAssertTrue(removed.isEmpty)
    }

    func testCorruptRatingsArePreservedAndRecoveredAsEmpty() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("media-ratings.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fileURL)

        let recovered = try await MediaRatingStore(fileURL: fileURL).items()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let recovery = try XCTUnwrap(
            files.first(where: { $0.lastPathComponent.contains(".corrupt-") })
        )

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: recovery), corrupt)
        XCTAssertEqual(
            try JSONDecoder().decode([MediaRating].self, from: Data(contentsOf: fileURL)),
            []
        )
    }

    func testRatingReadFailureIsNotMisclassifiedAsCorruptData() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("media-ratings.json")
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: true
        )

        do {
            _ = try await MediaRatingStore(fileURL: fileURL).items()
            XCTFail("Expected the ratings read to fail")
        } catch {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fileURL.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertTrue(try recoveryFiles(in: directory).isEmpty)
        }
    }

    func testHistoryReadFailureIsNotMisclassifiedAsCorruptData() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: true
        )

        do {
            _ = try await RecommendationHistoryStore(fileURL: fileURL).items()
            XCTFail("Expected the recommendation-history read to fail")
        } catch {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fileURL.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertTrue(try recoveryFiles(in: directory).isEmpty)
        }
    }

    func testLoveSignalsRankMatchingGenreAndActorWithReasons() {
        let loved = MediaRating(
            media: LocalMediaSnapshot(
                id: "loved",
                type: "movie",
                title: "Space Family",
                genres: ["Sci-Fi", "Drama"],
                actors: ["Ada Star"]
            ),
            reaction: .love,
            updatedAt: date(1)
        )
        let unrelated = media(
            id: "unrelated",
            name: "Cooking Hour",
            genres: ["Reality"]
        )
        let matching = media(
            id: "matching",
            name: "New Galaxy",
            genres: ["Sci-Fi"],
            actors: ["Ada Star"]
        )

        let result = LocalRecommendationEngine.recommend(
            candidates: [unrelated, matching],
            activity: [],
            ratings: [loved]
        )

        XCTAssertEqual(result.map(\.item.id), ["matching", "unrelated"])
        XCTAssertEqual(
            result[0].reasons,
            [
                "Because you enjoyed Space Family's Sci-Fi stories",
                "Featuring Ada Star",
            ]
        )
        XCTAssertGreaterThan(result[0].score, result[1].score)
    }

    func testRatedAndPreviouslyWatchedTitlesAreNotEchoedBack() {
        let ratedItem = media(id: "rated", name: "Rated", genres: ["Drama"])
        let watchedItem = media(id: "watched", name: "Watched", genres: ["Drama"])
        let freshItem = media(id: "fresh", name: "Fresh", genres: ["Drama"])
        let rating = MediaRating(
            media: LocalMediaSnapshot(item: ratedItem),
            reaction: .dislike,
            updatedAt: date(1)
        )
        let activity = RecommendationActivity(
            item: watchedItem,
            kind: .watched,
            occurredAt: date(2)
        )

        let result = LocalRecommendationEngine.recommend(
            candidates: [ratedItem, watchedItem, freshItem],
            activity: [activity],
            ratings: [rating]
        )

        XCTAssertEqual(result.map(\.item.id), ["fresh"])
    }

    func testRecommendationOrderIsDeterministicAndFallsBackToCatalogOrder() {
        let first = media(id: "1", name: "First", genres: ["Drama"])
        let second = media(id: "2", name: "Second", genres: ["Comedy"])

        let one = LocalRecommendationEngine.recommend(
            candidates: [first, second, first],
            activity: [],
            ratings: []
        )
        let two = LocalRecommendationEngine.recommend(
            candidates: [first, second, first],
            activity: [],
            ratings: []
        )

        XCTAssertEqual(one, two)
        XCTAssertEqual(one.map(\.item.id), ["1", "2"])
        XCTAssertEqual(one[0].reasons, ["More Drama from this catalog"])
    }

    func testImpressionPenaltyDiversifiesRepeatedRecommendations() {
        let signal = RecommendationActivity(
            item: media(id: "watched", name: "Drama", genres: ["Drama"]),
            kind: .completed,
            occurredAt: date(1)
        )
        let repeated = media(id: "repeat", name: "Repeated", genres: ["Drama"])
        let fresh = media(id: "fresh", name: "Fresh", genres: ["Drama"])
        let impression = RecommendationImpression(
            mediaID: LocalMediaIdentity(item: repeated),
            firstShownAt: date(2),
            lastShownAt: date(3),
            showCount: 5
        )

        let result = LocalRecommendationEngine.recommend(
            candidates: [repeated, fresh],
            activity: [signal],
            ratings: [],
            impressions: [impression]
        )

        XCTAssertEqual(result.map(\.item.id), ["fresh", "repeat"])
    }

    func testRecommendationPagerRevealsStableDeduplicatedWindows() {
        var pager = LocalRecommendationPager(pageSize: 3)
        let recommendations = (0..<8).map { index in
            LocalRecommendation(
                item: media(id: "\(index)", name: "Title \(index)"),
                score: Double(8 - index),
                reasons: ["Fixture"]
            )
        }

        pager.reset(with: recommendations + [recommendations[0]])

        XCTAssertEqual(pager.visibleRecommendations.map(\.item.id), ["0", "1", "2"])
        XCTAssertTrue(pager.canRevealMore)
        XCTAssertEqual(
            pager.revealNextPage().map(\.item.id),
            ["0", "1", "2", "3", "4", "5"]
        )
        XCTAssertEqual(
            pager.revealNextPage().map(\.item.id),
            ["0", "1", "2", "3", "4", "5", "6", "7"]
        )
        XCTAssertFalse(pager.canRevealMore)
    }

    func testRecommendationPagerAppendsProviderResultsWithoutReorderingVisibleItems() {
        let first = LocalRecommendation(
            item: media(id: "first", name: "First"),
            score: 4,
            reasons: ["Fixture"]
        )
        let second = LocalRecommendation(
            item: media(id: "second", name: "Second"),
            score: 3,
            reasons: ["Fixture"]
        )
        let later = LocalRecommendation(
            item: media(id: "later", name: "Later"),
            score: 10,
            reasons: ["Fixture"]
        )
        var pager = LocalRecommendationPager(pageSize: 2)
        pager.reset(with: [first, second])

        XCTAssertEqual(pager.appendRanked([later, first]), 1)
        XCTAssertEqual(pager.visibleRecommendations.map(\.item.id), ["first", "second"])
        XCTAssertEqual(
            pager.revealNextPage().map(\.item.id),
            ["first", "second", "later"]
        )
    }

    func testRecommendationHistoryPersistsIncrementsAndResets() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("history.json")
        let store = RecommendationHistoryStore(fileURL: fileURL)
        let recommendation = LocalRecommendation(
            item: media(id: "tt1", name: "Movie"),
            score: 4,
            reasons: ["More from this catalog"]
        )

        _ = try await store.record([recommendation], shownAt: date(1))
        let twice = try await store.record([recommendation], shownAt: date(2))
        XCTAssertEqual(twice.first?.showCount, 2)
        XCTAssertEqual(twice.first?.firstShownAt, date(1))
        XCTAssertEqual(twice.first?.lastShownAt, date(2))

        let reloaded = try await RecommendationHistoryStore(fileURL: fileURL).items()
        XCTAssertEqual(reloaded, twice)
        let reset = try await store.reset()
        let afterReset = try await RecommendationHistoryStore(fileURL: fileURL).items()
        XCTAssertTrue(reset.isEmpty)
        XCTAssertTrue(afterReset.isEmpty)
    }

    func testRecommendationHistorySaturatesPersistedMaximumCount() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("history.json")
        let impression = RecommendationImpression(
            mediaID: LocalMediaIdentity(id: "tt1", type: "movie"),
            firstShownAt: date(1),
            lastShownAt: date(2),
            showCount: .max
        )
        try writeHistory([impression], to: fileURL)
        let store = RecommendationHistoryStore(fileURL: fileURL)
        let recommendation = LocalRecommendation(
            item: media(id: "tt1", name: "Movie"),
            score: 4,
            reasons: ["Fixture"]
        )

        let updated = try await store.record([recommendation], shownAt: date(3))

        XCTAssertEqual(updated.first?.showCount, .max)
        XCTAssertEqual(updated.first?.lastShownAt, date(3))
    }

    func testRecommendationHistorySaturatesDuplicatePersistedCounts() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("history.json")
        let identity = LocalMediaIdentity(id: "tt1", type: "movie")
        try writeHistory(
            [
                RecommendationImpression(
                    mediaID: identity,
                    firstShownAt: date(1),
                    lastShownAt: date(2),
                    showCount: .max
                ),
                RecommendationImpression(
                    mediaID: identity,
                    firstShownAt: date(0),
                    lastShownAt: date(3),
                    showCount: 1
                ),
            ],
            to: fileURL
        )

        let items = try await RecommendationHistoryStore(fileURL: fileURL).items()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.showCount, .max)
        XCTAssertEqual(items.first?.firstShownAt, date(0))
        XCTAssertEqual(items.first?.lastShownAt, date(3))
    }

    func testRecommendationHistoryNormalizesPersistedNonpositiveCount() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("history.json")
        let persisted = """
        [{
          "mediaID":{"id":"tt1","type":"movie"},
          "firstShownAt":"1970-01-01T00:00:01Z",
          "lastShownAt":"1970-01-01T00:00:02Z",
          "showCount":-5
        }]
        """
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(persisted.utf8).write(to: fileURL)

        let items = try await RecommendationHistoryStore(fileURL: fileURL).items()

        XCTAssertEqual(items.first?.showCount, 1)
    }

    func testResetRatingsClearsPersistedPersonalization() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("ratings.json")
        let store = MediaRatingStore(fileURL: fileURL)
        _ = try await store.set(
            .love,
            for: media(id: "tt1", name: "Movie")
        )

        let reset = try await store.reset()
        let afterReset = try await MediaRatingStore(fileURL: fileURL).items()
        XCTAssertTrue(reset.isEmpty)
        XCTAssertTrue(afterReset.isEmpty)
    }

    private func media(
        id: String,
        name: String,
        genres: [String] = [],
        actors: [String] = []
    ) -> MetaItem {
        MetaItem(
            id: id,
            type: "movie",
            name: name,
            genres: genres,
            actors: actors
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func recoveryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    private func writeHistory(
        _ impressions: [RecommendationImpression],
        to fileURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(impressions).write(to: fileURL)
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}
