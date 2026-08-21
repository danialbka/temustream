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
            "/meta/movie/tt1254207.json": #"{"meta":{"id":"tt1254207","type":"movie","name":"Big Buck Bunny","description":"Open movie"}}"#,
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
        XCTAssertEqual(streams.first?.displayName, "Local MP4")
        XCTAssertTrue(streams.first?.isDirectlyPlayable == true)
        XCTAssertEqual(secondPage.map(\.name), ["Second Page"])
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
}
