import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private actor AccountStubLoader: HTTPRequestLoading {
    private(set) var requests: [URLRequest] = []
    private let libraryJSON: String

    init(libraryJSON: String? = nil) {
        self.libraryJSON = libraryJSON ?? #"[{"_id":"tt1","name":"Movie","type":"movie","poster":null,"posterShape":"poster","removed":false,"temp":false,"_ctime":"2026-08-20T00:00:00Z","_mtime":"2026-08-20T00:00:00Z","state":{"lastWatched":null,"timeWatched":0,"timeOffset":0,"overallTimeWatched":0,"timesWatched":0,"flaggedWatched":0,"duration":0,"video_id":null,"watched":null,"noNotif":false},"behaviorHints":{"defaultVideoId":null,"featuredVideoId":null,"hasScheduledVideos":false}}]"#
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let json: String
        switch request.url?.lastPathComponent {
        case "login":
            json = #"{"result":{"authKey":"secret","user":{"_id":"u1","email":"person@example.test"}}}"#
        case "datastoreGet":
            json = #"{"result":\#(libraryJSON)}"#
        case "addonCollectionGet":
            json = #"{"result":{"addons":[{"manifest":{"id":"org.test","version":"1.0.0","name":"Test","resources":["stream"],"types":["movie"],"catalogs":[]},"transportUrl":"https://example.com/manifest.json","flags":{"official":false,"protected":false}}]}}"#
        default:
            json = #"{"result":{"success":true}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }
}

final class StremioAccountClientTests: XCTestCase {
    func testLoginAndLibraryAddonRoundTrip() async throws {
        let loader = AccountStubLoader()
        let client = try StremioAccountClient(
            endpoint: URL(string: "https://api.example.test")!,
            loader: loader
        )

        let session = try await client.login(email: "person@example.test", password: "password")
        let library = try await client.pullLibrary(authKey: session.authKey)
        let addons = try await client.pullAddons(authKey: session.authKey)
        try await client.pushLibrary(authKey: session.authKey, changes: library)
        try await client.pushAddons(authKey: session.authKey, addons: addons)

        XCTAssertEqual(session.user.email, "person@example.test")
        XCTAssertEqual(library.first?.metaItem.name, "Movie")
        XCTAssertEqual(addons.first?.transportUrl.absoluteString, "https://example.com/manifest.json")
        let paths = await loader.requests.compactMap { $0.url?.lastPathComponent }
        XCTAssertEqual(
            paths,
            ["login", "datastoreGet", "addonCollectionGet", "datastorePut", "addonCollectionSet"]
        )
    }

    func testRejectsInsecureAccountEndpoint() {
        XCTAssertThrowsError(
            try StremioAccountClient(endpoint: URL(string: "http://api.example.test")!)
        )
    }

    func testLibraryPullTreatsInvalidPostersAsMissingAndSkipsMalformedItems() async throws {
        let libraryJSON = #"""
        [
            "corrupt",
            {"_id":"bad","name":"Missing type"},
            {"_id":"tt2","name":"Valid Movie","type":"movie","poster":"not a valid absolute url","removed":false,"temp":false,"_mtime":"2026-08-20T00:00:00Z","state":{}}
        ]
        """#
        let client = try StremioAccountClient(
            endpoint: URL(string: "https://api.example.test")!,
            loader: AccountStubLoader(libraryJSON: libraryJSON)
        )

        let library = try await client.pullLibrary(authKey: "secret")

        XCTAssertEqual(library.map(\.id), ["tt2"])
        XCTAssertNil(library.first?.poster)
    }
}
