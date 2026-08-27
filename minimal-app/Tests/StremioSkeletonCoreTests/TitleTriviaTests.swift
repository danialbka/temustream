import XCTest
@testable import StremioSkeletonCore

final class TitleTriviaTests: XCTestCase {
    func testOrdinaryMetadataIsNotRelabelledAsTrivia() {
        let item = MetaItem(
            id: "tt-series-trivia",
            type: "series",
            name: "Series Fixture",
            writer: ["Writer One", "Writer Two"],
            country: "United States",
            awards: "Won 4 awards.",
            status: "Continuing",
            released: "2020-05-04T00:00:00.000Z",
            videos: [
                Video(id: "special", season: 0, episode: 1),
                Video(id: "s1e1", season: 1, episode: 1),
                Video(id: "s1e2", season: 1, episode: 2),
                Video(id: "s2e1", season: 2, episode: 1),
            ]
        )

        XCTAssertTrue(TitleTriviaBuilder.facts(for: item).isEmpty)
    }

    func testProviderTriviaIsNormalizedDeduplicatedAndBounded() {
        let item = MetaItem(
            id: "tt-movie-trivia",
            type: "movie",
            name: "Movie Fixture",
            runtime: "95 min",
            director: ["Director One"],
            writer: ["Writer One"],
            country: "New Zealand",
            awards: "2 nominations.",
            released: "2022-11-09T00:00:00.000Z",
            trivia: ["Shot on location.", " shot on location. "],
            funFacts: ["Used   practical effects.", "A third fact."]
        )

        let facts = TitleTriviaBuilder.facts(for: item, limit: 2)

        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[0].text, "Shot on location.")
        XCTAssertEqual(facts[1].text, "Used practical effects.")
        XCTAssertTrue(facts.allSatisfy { !$0.isSpoiler })
    }

    func testSpoilerPrefixIsRemovedAndPreservedAsPresentationMetadata() {
        let item = MetaItem(
            id: "tt-spoiler-trivia",
            type: "movie",
            name: "Spoiler Fixture",
            trivia: ["SPOILER: The final scene mirrors the opening.", "spoiler:   "]
        )

        let facts = TitleTriviaBuilder.facts(for: item)

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].text, "The final scene mirrors the opening.")
        XCTAssertTrue(facts[0].isSpoiler)
    }

    func testTitleWithoutSupportedFactsOmitsTriviaSection() {
        let item = MetaItem(id: "tt-empty", type: "movie", name: "Empty Fixture")

        XCTAssertTrue(TitleTriviaBuilder.facts(for: item).isEmpty)
        XCTAssertTrue(TitleTriviaBuilder.facts(for: item, limit: 0).isEmpty)
    }
}
