import XCTest
@testable import StremioSkeletonCore

final class TitleTriviaTests: XCTestCase {
    func testSeriesFactsUseAwardsEpisodeInventoryStatusAndPremiere() {
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

        let facts = TitleTriviaBuilder.facts(for: item)

        XCTAssertEqual(facts.map(\.kind), [
            .awards, .episodes, .status, .release, .writing, .origin,
        ])
        XCTAssertEqual(
            facts.first(where: { $0.kind == .episodes })?.text,
            "The provider lists 3 episodes across 2 seasons."
        )
        XCTAssertEqual(
            facts.first(where: { $0.kind == .release })?.text,
            "Premiered on May 4, 2020."
        )
    }

    func testMovieFactsPrioritizeExplicitTriviaAndStayBounded() {
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
            funFacts: ["Used practical effects."]
        )

        let facts = TitleTriviaBuilder.facts(for: item, limit: 4)

        XCTAssertEqual(facts.count, 4)
        XCTAssertEqual(facts.map(\.kind), [.provided, .provided, .awards, .release])
        XCTAssertEqual(facts[0].text, "Shot on location.")
        XCTAssertEqual(facts[1].text, "Used practical effects.")
        XCTAssertEqual(facts[3].text, "Released on November 9, 2022.")
    }

    func testTitleWithoutSupportedFactsOmitsTriviaSection() {
        let item = MetaItem(id: "tt-empty", type: "movie", name: "Empty Fixture")

        XCTAssertTrue(TitleTriviaBuilder.facts(for: item).isEmpty)
        XCTAssertTrue(TitleTriviaBuilder.facts(for: item, limit: 0).isEmpty)
    }
}
