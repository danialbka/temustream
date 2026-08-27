import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private actor TorrentStubLoader: HTTPRequestLoading {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let payload = request.url?.path == "/settings"
            ? #"{"values":{"transcodeProfile":null,"allTranscodeProfiles":["videotoolbox"],"transcodeMaxWidth":1280}}"#
            : #"{"success":true}"#
        return (Data(payload.utf8), response)
    }
}

final class TorrentStreamingClientTests: XCTestCase {
    func testResolvesTorrentThroughCompatibleServer() async throws {
        let loader = TorrentStubLoader()
        let endpoint = try StreamingServerEndpoint("http://192.168.1.20:11470/")
        let client = TorrentStreamingClient(endpoint: endpoint, loader: loader)
        let stream = Stream(
            url: nil,
            externalUrl: nil,
            name: "Public domain",
            title: nil,
            description: nil,
            infoHash: "08ADA5A7A6183AAE1E09D831DF6748D566095A10",
            fileIdx: 2,
            sources: ["tracker:udp://tracker.example.test:80"]
        )

        let url = try await client.playbackURL(for: stream)

        XCTAssertEqual(url.path, "/08ada5a7a6183aae1e09d831df6748d566095a10/2")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "tr", value: "udp://tracker.example.test:80")]
        )
        let recorded = await loader.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/08ada5a7a6183aae1e09d831df6748d566095a10/create")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let peerSearch = try XCTUnwrap(json["peerSearch"] as? [String: Any])
        let sources = try XCTUnwrap(peerSearch["sources"] as? [String])
        XCTAssertTrue(sources.contains("dht:08ada5a7a6183aae1e09d831df6748d566095a10"))
    }

    func testRejectsInsecurePublicServerAndBadHash() async throws {
        XCTAssertThrowsError(try StreamingServerEndpoint("http://example.com:11470"))
        XCTAssertThrowsError(
            try StreamingServerEndpoint("https://user:secret@stream.example.test:11470")
        )
        XCTAssertThrowsError(
            try StreamingServerEndpoint("https://stream.example.test:11470?token=secret")
        )
        let client = TorrentStreamingClient(
            endpoint: try StreamingServerEndpoint("http://127.0.0.1:11470"),
            loader: TorrentStubLoader()
        )
        let stream = Stream(
            url: nil,
            externalUrl: nil,
            name: nil,
            title: nil,
            description: nil,
            infoHash: "bad",
            fileIdx: nil,
            sources: nil
        )
        do {
            _ = try await client.playbackURL(for: stream)
            XCTFail("Expected invalid hash")
        } catch {
            XCTAssertEqual(error as? StreamingServerError, .invalidInfoHash)
        }
    }

    func testBuildsHardwareAcceleratedCompatibilityPlaylist() async throws {
        let loader = TorrentStubLoader()
        let client = TorrentStreamingClient(
            endpoint: try StreamingServerEndpoint("http://127.0.0.1:11470"),
            loader: loader
        )

        let url = try await client.compatibilityPlaybackURL(
            for: URL(string: "https://media.example.test/movie.mkv")!,
            sessionID: "fixture-session"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/hlsv2/fixture-session/master.m3u8")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "mediaURL" })?.value,
            "https://media.example.test/movie.mkv"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "profile" })?.value,
            "videotoolbox"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "forceTranscoding" })?.value,
            "1"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "maxWidth" })?.value,
            "1280"
        )
        let recorded = await loader.requests
        XCTAssertEqual(recorded.first?.timeoutInterval, 3)
    }

    func testHeartbeatFailsFastWhenCompatibilityServerIsUnavailable() async throws {
        let loader = TorrentStubLoader()
        let client = TorrentStreamingClient(
            endpoint: try StreamingServerEndpoint("http://127.0.0.1:11470"),
            loader: loader
        )

        let isOnline = await client.isOnline()
        XCTAssertTrue(isOnline)
        let recorded = await loader.requests
        XCTAssertEqual(recorded.first?.url?.path, "/heartbeat")
        XCTAssertEqual(recorded.first?.timeoutInterval, 2)
    }

    func testDetectsStreamsThatNeedCompatibilityPlayback() {
        let mkv = Stream(
            url: URL(string: "https://media.example.test/movie.mkv"),
            externalUrl: nil,
            name: nil,
            title: nil,
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
        let av1 = Stream(
            url: URL(string: "https://media.example.test/download/123"),
            externalUrl: nil,
            name: "Movie 2160p AV1 FLAC",
            title: nil,
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
        let native = Stream(
            url: URL(string: "https://media.example.test/movie.mp4"),
            externalUrl: nil,
            name: "H.264 AAC",
            title: nil,
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )

        XCTAssertTrue(mkv.prefersCompatibilityPlayback)
        XCTAssertTrue(av1.prefersCompatibilityPlayback)
        XCTAssertFalse(native.prefersCompatibilityPlayback)
    }
}
