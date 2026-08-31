import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private actor AccountStubLoader: HTTPRequestLoading {
    private(set) var requests: [URLRequest] = []
    private let libraryJSON: String
    private let mutationSuccess: Bool

    init(libraryJSON: String? = nil, mutationSuccess: Bool = true) {
        self.libraryJSON = libraryJSON ?? #"[{"_id":"tt1","name":"Movie","type":"movie","poster":null,"posterShape":"poster","removed":false,"temp":false,"_ctime":"2026-08-20T00:00:00Z","_mtime":"2026-08-20T00:00:00Z","state":{"lastWatched":null,"timeWatched":0,"timeOffset":0,"overallTimeWatched":0,"timesWatched":0,"flaggedWatched":0,"duration":0,"video_id":null,"watched":null,"noNotif":false},"behaviorHints":{"defaultVideoId":null,"featuredVideoId":null,"hasScheduledVideos":false}}]"#
        self.mutationSuccess = mutationSuccess
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
            json = #"{"result":{"success":\#(mutationSuccess)}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }
}

private actor StatefulAddonLoader: HTTPRequestLoading {
    private struct AddonSetBody: Decodable {
        let addons: [SyncedAddon]
    }

    private struct AddonCollectionEnvelope: Encodable {
        struct Result: Encodable {
            let addons: [SyncedAddon]
        }

        let result: Result
    }

    private struct SuccessEnvelope: Encodable {
        struct Result: Encodable {
            let success: Bool
        }

        let result = Result(success: true)
    }

    private var addons: [SyncedAddon]
    private var requestPaths: [String] = []
    private var setCount = 0
    private var firstSetStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSetRelease: CheckedContinuation<Void, Never>?

    init(addons: [SyncedAddon]) {
        self.addons = addons
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.lastPathComponent ?? ""
        requestPaths.append(path)
        let data: Data
        switch path {
        case "addonCollectionGet":
            data = try JSONEncoder().encode(
                AddonCollectionEnvelope(result: .init(addons: addons))
            )
        case "addonCollectionSet":
            let body = try JSONDecoder().decode(
                AddonSetBody.self,
                from: try XCTUnwrap(request.httpBody)
            )
            setCount += 1
            if setCount == 1 {
                let waiters = firstSetStartedWaiters
                firstSetStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { continuation in
                    firstSetRelease = continuation
                }
            }
            addons = body.addons
            data = try JSONEncoder().encode(SuccessEnvelope())
        default:
            throw URLError(.unsupportedURL)
        }

        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (data, response)
    }

    func waitUntilFirstSetStarts() async {
        if setCount > 0 { return }
        await withCheckedContinuation { continuation in
            firstSetStartedWaiters.append(continuation)
        }
    }

    func releaseFirstSet() {
        firstSetRelease?.resume()
        firstSetRelease = nil
    }

    func paths() -> [String] {
        requestPaths
    }

    func remoteAddons() -> [SyncedAddon] {
        addons
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

    func testLoginPreservesOpaquePasswordBytesAfterFormValidation() async throws {
        let loader = AccountStubLoader()
        let client = try StremioAccountClient(
            endpoint: URL(string: "https://api.example.test")!,
            loader: loader
        )
        let suppliedPassword = "  space-sensitive secret  "
        let credentials = try SignInFormCredentials(
            email: "  person@example.test\n",
            password: suppliedPassword
        )

        _ = try await client.login(
            email: credentials.email,
            password: credentials.password
        )

        let requests = await loader.requests
        let request = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["email"] as? String, "person@example.test")
        XCTAssertEqual(object["password"] as? String, suppliedPassword)
        XCTAssertEqual((object["password"] as? String)?.utf8.count, 26)
    }

    func testRejectsInsecureAccountEndpoint() {
        XCTAssertThrowsError(
            try StremioAccountClient(endpoint: URL(string: "http://api.example.test")!)
        )
    }

    func testPushesRejectNegativeSemanticAcknowledgement() async throws {
        let loader = AccountStubLoader(mutationSuccess: false)
        let client = try StremioAccountClient(
            endpoint: URL(string: "https://api.example.test")!,
            loader: loader
        )

        do {
            try await client.pushLibrary(authKey: "secret", changes: [])
            XCTFail("A rejected library mutation must throw")
        } catch {
            XCTAssertEqual(error as? StremioAccountError, .updateRejected)
        }

        do {
            try await client.pushAddons(authKey: "secret", addons: [])
            XCTFail("A rejected add-on mutation must throw")
        } catch {
            XCTAssertEqual(error as? StremioAccountError, .updateRejected)
        }

        let paths = await loader.requests.compactMap { $0.url?.lastPathComponent }
        XCTAssertEqual(paths, ["datastorePut", "addonCollectionSet"])
    }

    func testLibraryPullRejectsMalformedCompleteSnapshot() async throws {
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

        do {
            _ = try await client.pullLibrary(authKey: "secret")
            XCTFail("A complete snapshot with one malformed row must be rejected")
        } catch let StremioAccountError.decoding(method, path, _) {
            XCTAssertEqual(method, "datastoreGet")
            XCTAssertTrue(path.hasPrefix("result."), path)
        }
    }

    func testLibraryPullStillTreatsInvalidOptionalPosterAsMissing() async throws {
        let libraryJSON = #"""
        [
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

    func testMalformedRemoteRowCannotDeleteOmittedLocalLibraryItem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(
            fileURL: directory.appendingPathComponent("library.json")
        )
        let first = MetaItem(id: "tt-a", type: "movie", name: "A")
        let second = MetaItem(id: "tt-b", type: "movie", name: "B")
        _ = try await store.merge([first, second])
        let malformedSnapshot = #"""
        [
            {"_id":"tt-a","name":"A","type":"movie","removed":false,"_mtime":"2026-08-20T00:00:00Z","state":{}},
            {"_id":"tt-b","name":"B without a type"}
        ]
        """#
        let client = try StremioAccountClient(
            endpoint: URL(string: "https://api.example.test")!,
            loader: AccountStubLoader(libraryJSON: malformedSnapshot)
        )
        let coordinator = LibraryMutationCoordinator()

        do {
            _ = try await coordinator.synchronize(
                store: store,
                remoteSnapshot: {
                    try await client.pullLibrary(authKey: "secret")
                }
            )
            XCTFail("A malformed complete snapshot must not reach the store commit")
        } catch {
            XCTAssertNotNil(error as? StremioAccountError)
        }

        let reloaded = try await LibraryStore(
            fileURL: directory.appendingPathComponent("library.json")
        ).items()
        XCTAssertEqual(Set(reloaded.map(\.id)), Set([first.id, second.id]))
    }

    func testAddonSyncCoordinatorSerializesMutationsAndPreservesUnknownRemoteAddons() async throws {
        let existing = syncedAddon(id: "org.remote", host: "remote.example.test")
        let installed = syncedAddon(id: "org.installed", host: "installed.example.test")
        let loader = StatefulAddonLoader(addons: [existing])
        let client = try StremioAccountClient(
            endpoint: URL(string: "https://api.example.test")!,
            loader: loader
        )
        let coordinator = StremioAddonSyncCoordinator(client: client)

        let installTask = Task {
            try await coordinator.install(installed, authKey: "secret")
        }
        await loader.waitUntilFirstSetStarts()

        let removeTask = Task {
            try await coordinator.remove(
                transportURL: installed.transportUrl,
                authKey: "secret"
            )
        }
        await Task.yield()
        let pathsWhileBlocked = await loader.paths()
        XCTAssertEqual(
            pathsWhileBlocked,
            ["addonCollectionGet", "addonCollectionSet"],
            "A second mutation must wait until the preceding full-snapshot push completes."
        )

        await loader.releaseFirstSet()
        let installedSnapshot = try await installTask.value
        let removedSnapshot = try await removeTask.value

        XCTAssertEqual(Set(installedSnapshot.map(\.transportUrl)), [
            existing.transportUrl,
            installed.transportUrl,
        ])
        XCTAssertEqual(removedSnapshot.map(\.transportUrl), [existing.transportUrl])
        let finalRemoteURLs = await loader.remoteAddons().map(\.transportUrl)
        let finalPaths = await loader.paths()
        XCTAssertEqual(finalRemoteURLs, [existing.transportUrl])
        XCTAssertEqual(
            finalPaths,
            [
                "addonCollectionGet",
                "addonCollectionSet",
                "addonCollectionGet",
                "addonCollectionSet",
            ]
        )
    }

    private func syncedAddon(id: String, host: String) -> SyncedAddon {
        SyncedAddon(
            manifest: AddonManifest(
                id: id,
                version: "1.0.0",
                name: id,
                resources: [.name("stream")],
                types: ["movie"],
                catalogs: []
            ),
            transportUrl: URL(string: "https://\(host)/manifest.json")!
        )
    }
}
