import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private actor WikipediaStubLoader: HTTPRequestLoading {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        let payload: String
        if url.host == "query.wikidata.org" {
            payload = #"{"results":{"bindings":[{"article":{"type":"uri","value":"https://en.wikipedia.org/wiki/Big_Buck_Bunny"}}]}}"#
        } else if queryItems["prop"] == "sections|revid" {
            payload = #"{"parse":{"title":"Big Buck Bunny","pageid":1037763,"revid":1357911,"sections":[{"level":"2","line":"Plot","index":"1"},{"level":"2","line":"Production","index":"2"},{"level":"3","line":"Casting","index":"2.1"},{"level":"2","line":"Music and release","index":"3"},{"level":"2","line":"References","index":"4"}]}}"#
        } else if queryItems["section"] == "2" {
            payload = #"{"parse":{"text":"<div><h2>Production</h2><p>The film was made with <i>open-source</i> tools &amp; community support.<sup class=\"reference\">[1]</sup></p><p>Work began in October 2007 and the production assets were later released publicly.</p></div>"}}"#
        } else if queryItems["section"] == "3" {
            payload = #"{"parse":{"text":"<div><p>The score was recorded specifically for the film.</p></div>"}}"#
        } else {
            XCTFail("Unexpected Wikipedia request: \(url.absoluteString)")
            payload = #"{"parse":{"text":""}}"#
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(payload.utf8), response)
    }
}

final class WikipediaTriviaTests: XCTestCase {
    func testCanonicalIMDbIdentifierAcceptsTitleAndEpisodeIDs() {
        XCTAssertEqual(WikipediaTitleIdentifier.imdbID(from: "tt1254207"), "tt1254207")
        XCTAssertEqual(WikipediaTitleIdentifier.imdbID(from: "TT1254207:1:2"), "tt1254207")
        XCTAssertNil(WikipediaTitleIdentifier.imdbID(from: "tmdb:123"))
        XCTAssertNil(WikipediaTitleIdentifier.imdbID(from: "tt-fixture"))
        XCTAssertNil(WikipediaTitleIdentifier.imdbID(from: "tt123"))
        XCTAssertNil(WikipediaTitleIdentifier.imdbID(from: "tt12345"))
    }

    func testLoadsExactWikipediaProductionTriviaWithRevisionAttribution() async throws {
        let loader = WikipediaStubLoader()
        let client = WikipediaTriviaClient(
            loader: loader,
            maximumSections: 4,
            excerptsPerSection: 2
        )

        let trivia = try await client.trivia(forIMDbID: "tt1254207")

        XCTAssertEqual(trivia.pageTitle, "Big Buck Bunny")
        XCTAssertEqual(trivia.revisionID, 1_357_911)
        XCTAssertEqual(trivia.sections.map(\.title), ["Production", "Music and release"])
        XCTAssertEqual(
            trivia.excerpts.map(\.text),
            [
                "The film was made with open-source tools & community support.",
                "Work began in October 2007 and the production assets were later released publicly.",
                "The score was recorded specifically for the film.",
            ]
        )
        XCTAssertEqual(trivia.articleURL.absoluteString, "https://en.wikipedia.org/wiki/Big_Buck_Bunny")
        XCTAssertTrue(trivia.revisionURL.absoluteString.contains("oldid=1357911"))
        XCTAssertTrue(trivia.revisionURL.absoluteString.contains("title=Big%20Buck%20Bunny"))

        let requests = await loader.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("TemuStremio/") == true
        })
        let wikidataQuery = try XCTUnwrap(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value
        )
        XCTAssertTrue(wikidataQuery.contains("wdt:P345 \"tt1254207\""))
        XCTAssertTrue(wikidataQuery.contains("https://en.wikipedia.org/"))
        XCTAssertEqual(
            requests.filter { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "oldid" && $0.value == "1357911" })
                    == true
            }.count,
            2
        )
    }

    func testRejectsUnsupportedIdentifierWithoutNetworkTraffic() async {
        let loader = WikipediaStubLoader()
        let client = WikipediaTriviaClient(loader: loader)

        do {
            _ = try await client.trivia(forIMDbID: "movie-name")
            XCTFail("Expected unsupported identifier")
        } catch {
            XCTAssertEqual(error as? WikipediaTriviaError, .unsupportedIdentifier)
        }
        let requests = await loader.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLiveConfiguredTitleLookupWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WIKIPEDIA_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set WIKIPEDIA_LIVE_TEST=1 to exercise Wikimedia's live APIs")
        }
        let imdbID = environment["WIKIPEDIA_LIVE_IMDB_ID"] ?? "tt1254207"

        let trivia = try await WikipediaTriviaClient().trivia(forIMDbID: imdbID)

        XCTAssertEqual(trivia.articleURL.host, "en.wikipedia.org")
        XCTAssertGreaterThan(trivia.revisionID, 0)
        XCTAssertFalse(trivia.sections.isEmpty)
        XCTAssertFalse(trivia.excerpts.isEmpty)
        XCTAssertTrue(trivia.sections.contains { section in
            section.title.localizedCaseInsensitiveContains("production")
        })
    }
}
