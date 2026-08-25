import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private actor StubLoader: HTTPDataLoading {
    private let responses: [String: Data]

    init(responses: [String: String]) {
        self.responses = responses.mapValues { Data($0.utf8) }
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        let data = responses[url.path] ?? Data(#"{"streams":[]}"#.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

final class AddonClientTests: XCTestCase {
    func testLoadsManifestCatalogMetaAndStreams() async throws {
        let loader = StubLoader(responses: [
            "/manifest.json": #"{"id":"org.test","version":"1.0.0","name":"Test","resources":["catalog","meta","stream"],"types":["movie"],"catalogs":[{"type":"movie","id":"public","name":"Public"}]}"#,
            "/catalog/movie/public.json": #"{"metas":[{"id":"tt1254207","type":"movie","name":"Big Buck Bunny"}]}"#,
            "/catalog/movie/public/skip=1.json": #"{"metas":[{"id":"tt0000002","type":"movie","name":"Second Page"}]}"#,
            "/meta/movie/tt1254207.json": #"{"meta":{"id":"tt1254207","type":"movie","name":"Big Buck Bunny","description":"Open movie","cast":["Bunny","Squirrel"],"trailerStreams":[{"title":"Official trailer","ytId":"yUQM7H4Swgw"}]}}"#,
            "/stream/movie/tt1254207.json": #"{"streams":[{"name":"Local MP4","url":"http://127.0.0.1:8765/sample.mp4"}]}"#,
        ])
        let endpoint = try AddonEndpoint(manifestInput: "https://example.com/manifest.json")
        let client = AddonClient(endpoint: endpoint, loader: loader)

        let manifest = try await client.manifest()
        let catalog = try await client.catalog(type: "movie", id: "public")
        let meta = try await client.meta(type: "movie", id: catalog[0].id)
        let streams = try await client.streams(type: "movie", id: meta.id)
        let secondPage = try await client.catalog(type: "movie", id: "public", skip: 1)

        XCTAssertEqual(manifest.name, "Test")
        XCTAssertEqual(catalog.map(\.name), ["Big Buck Bunny"])
        XCTAssertEqual(meta.description, "Open movie")
        XCTAssertEqual(meta.actorNames, ["Bunny", "Squirrel"])
        XCTAssertEqual(
            meta.preferredTrailerURL?.absoluteString,
            "https://www.youtube.com/watch?v=yUQM7H4Swgw"
        )
        XCTAssertEqual(streams.first?.displayName, "Local MP4")
        XCTAssertTrue(streams.first?.isDirectlyPlayable == true)
        XCTAssertEqual(secondPage.map(\.name), ["Second Page"])
    }

    func testMergesCastAndCommunityActorsWithoutDuplicates() throws {
        let json = #"{"id":"tt-cast","type":"series","name":"Cast Fixture","cast":["Ada Star","Bo Ray"],"actors":[" ada star ","Cy Moon"]}"#

        let meta = try JSONDecoder().decode(MetaItem.self, from: Data(json.utf8))

        XCTAssertEqual(meta.actorNames, ["Ada Star", "Bo Ray", "Cy Moon"])
    }

    func testDecodesProviderTriviaAndRichFactFieldsWithoutBreakingMetadata() throws {
        let json = #"{"id":"tt-trivia","type":"series","name":"Trivia Fixture","awards":"Won 3 awards.","status":"Continuing","released":"2020-05-04T00:00:00.000Z","trivia":"A provider supplied fact.","funFacts":["Another fact.","A provider supplied fact."]}"#

        let meta = try JSONDecoder().decode(MetaItem.self, from: Data(json.utf8))

        XCTAssertEqual(meta.awards, "Won 3 awards.")
        XCTAssertEqual(meta.status, "Continuing")
        XCTAssertEqual(meta.released, "2020-05-04T00:00:00.000Z")
        XCTAssertEqual(meta.explicitTriviaFacts, [
            "A provider supplied fact.",
            "Another fact.",
        ])
    }

    func testUnsupportedCommunityTriviaShapeDoesNotRejectTheTitle() throws {
        let json = #"{"id":"tt-trivia-object","type":"movie","name":"Object Fixture","trivia":{"text":"Unknown shape"}}"#

        let meta = try JSONDecoder().decode(MetaItem.self, from: Data(json.utf8))

        XCTAssertEqual(meta.name, "Object Fixture")
        XCTAssertTrue(meta.explicitTriviaFacts.isEmpty)
    }

    func testManifestMatchesStreamCapabilityByResourceAndType() throws {
        let json = #"""
        {
            "id":"org.test","version":"1.0.0","name":"Test",
            "resources":["subtitles",{"name":"stream","types":["movie"]}],
            "types":["movie","series"],"catalogs":[]
        }
        """#
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8))

        XCTAssertTrue(manifest.supports(resource: "stream", type: "movie"))
        XCTAssertFalse(manifest.supports(resource: "stream", type: "series"))
        XCTAssertTrue(manifest.supports(resource: "subtitles", type: "series"))
        XCTAssertFalse(manifest.supports(resource: "catalog", type: "movie"))
    }

    func testLegacyTrailerAndMetadataFallbackResolveToPlayableURLs() throws {
        let legacyJSON = #"{"id":"tt1","type":"movie","name":"Movie","cast":["Ari Actor","Sam Star"],"trailers":[{"source":"abc_123-XYZ","type":"Trailer"}]}"#
        let fallback = try JSONDecoder().decode(MetaItem.self, from: Data(legacyJSON.utf8))
        let providerDetail = MetaItem(
            id: "tt1",
            type: "movie",
            name: "Movie",
            description: "Provider description"
        )

        let enriched = providerDetail.fillingTrailerMetadata(from: fallback)

        XCTAssertEqual(enriched.description, "Provider description")
        XCTAssertEqual(enriched.actorNames, ["Ari Actor", "Sam Star"])
        XCTAssertEqual(
            enriched.preferredTrailerURL?.absoluteString,
            "https://www.youtube.com/watch?v=abc_123-XYZ"
        )
    }

    func testSeriesTrailerAndMetadataFallbackResolveToPlayableURLs() throws {
        let seriesJSON = #"{"id":"tt-series","type":"series","name":"Series","trailerStreams":[{"title":"Official trailer","ytId":"series_trailer_123"}]}"#
        let fallback = try JSONDecoder().decode(MetaItem.self, from: Data(seriesJSON.utf8))
        let providerDetail = MetaItem(
            id: "tt-series",
            type: "series",
            name: "Series",
            description: "Provider description",
            videos: [Video(id: "tt-series:1:1", title: "Pilot", season: 1, episode: 1)]
        )

        let enriched = providerDetail.fillingTrailerMetadata(from: fallback)

        XCTAssertEqual(enriched.type, "series")
        XCTAssertEqual(enriched.description, "Provider description")
        XCTAssertEqual(enriched.videos?.first?.title, "Pilot")
        XCTAssertEqual(
            enriched.preferredTrailerURL?.absoluteString,
            "https://www.youtube.com/watch?v=series_trailer_123"
        )
    }

    func testSparsePreferredSeriesFillsMissingPresentationAndEpisodeMetadata() throws {
        let preferred = MetaItem(
            id: "tt-series",
            type: "series",
            name: "Series",
            description: "   ",
            runtime: "48 min",
            videos: []
        )
        let fallback = MetaItem(
            id: "tt-series",
            type: "series",
            name: "Series",
            poster: URL(string: "https://images.example/series-poster.jpg"),
            background: URL(string: "https://images.example/series-background.jpg"),
            description: "Fallback synopsis",
            releaseInfo: "2024–",
            runtime: "52 min",
            videos: [
                Video(
                    id: "tt-series:1:1",
                    title: "Pilot",
                    season: 1,
                    episode: 1,
                    overview: "The story begins."
                ),
            ]
        )

        let enriched = preferred.fillingTrailerMetadata(from: fallback)

        XCTAssertEqual(enriched.poster, fallback.poster)
        XCTAssertEqual(enriched.background, fallback.background)
        XCTAssertEqual(enriched.description, "Fallback synopsis")
        XCTAssertEqual(enriched.releaseInfo, "2024–")
        XCTAssertEqual(enriched.videos, fallback.videos)
        XCTAssertEqual(enriched.runtime, "48 min", "Preferred non-empty values must still win")
    }

    func testDecodesEpisodeThumbnailFromSeriesMetadata() throws {
        let json = #"""
        {
            "id":"tt9288030:1:1",
            "title":"Welcome to Margrave",
            "season":1,
            "episode":1,
            "thumbnail":"https://episodes.metahub.space/tt9288030/1/1/w780.jpg",
            "overview":"Jack Reacher investigates a small-town murder with unexpected ties.",
            "released":"2022-02-04T00:00:00.000Z"
        }
        """#

        let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))

        XCTAssertEqual(video.season, 1)
        XCTAssertEqual(video.episode, 1)
        XCTAssertEqual(
            video.thumbnail?.absoluteString,
            "https://episodes.metahub.space/tt9288030/1/1/w780.jpg"
        )
        XCTAssertEqual(
            video.overview,
            "Jack Reacher investigates a small-town murder with unexpected ties."
        )
    }
}
