import XCTest
@testable import StremioSkeletonCore

final class WatchStreamCompatibilityTests: XCTestCase {
    func testAcceptsHTTPSHLSAndDirectVideo() throws {
        let hls = WatchStreamCompatibility.assess(
            url: try XCTUnwrap(URL(string: "https://media.example.test/live/master.m3u8"))
        )
        let file = WatchStreamCompatibility.assess(
            url: try XCTUnwrap(URL(string: "https://media.example.test/movie.mp4"))
        )

        XCTAssertTrue(hls.isPlayable)
        XCTAssertEqual(hls.kind, .hls)
        XCTAssertTrue(file.isPlayable)
        XCTAssertEqual(file.kind, .directFile)
    }

    func testRejectsInsecureAndUnsupportedContainers() throws {
        let insecure = WatchStreamCompatibility.assess(
            url: try XCTUnwrap(URL(string: "http://media.example.test/movie.mp4"))
        )
        let unsupported = WatchStreamCompatibility.assess(
            url: try XCTUnwrap(URL(string: "https://media.example.test/movie.mkv"))
        )

        XCTAssertEqual(insecure.incompatibility, .insecureTransport)
        XCTAssertEqual(unsupported.incompatibility, .unsupportedContainer("mkv"))
    }

    func testRejectsTorrentAndExternalOnlyStreams() throws {
        let torrent = Stream(
            url: nil,
            externalUrl: nil,
            name: "Torrent",
            title: nil,
            description: nil,
            infoHash: "0123456789abcdef",
            fileIdx: 0,
            sources: nil
        )
        let external = Stream(
            url: nil,
            externalUrl: try XCTUnwrap(URL(string: "https://example.test/open")),
            name: "External",
            title: nil,
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )

        XCTAssertEqual(WatchStreamCompatibility.assess(torrent).incompatibility, .torrent)
        XCTAssertEqual(WatchStreamCompatibility.assess(external).incompatibility, .externalOnly)
    }

    func testRejectsCredentialsEmbeddedInURL() throws {
        let result = WatchStreamCompatibility.assess(
            url: try XCTUnwrap(URL(string: "https://user:password@example.test/video.mp4"))
        )

        XCTAssertEqual(result.incompatibility, .embeddedCredentials)
    }

    func testAcceptsPrivateHTTPOnlyFromConfiguredStreamingServerOrigin() throws {
        let endpoint = try StreamingServerEndpoint("http://192.168.1.20:11470")
        let output = try XCTUnwrap(
            URL(string: "http://192.168.1.20:11470/hlsv2/session/master.m3u8")
        )

        let directAssessment = WatchStreamCompatibility.assess(url: output)
        let serverAssessment = WatchStreamCompatibility.assessStreamingServerURL(
            output,
            endpoint: endpoint
        )

        XCTAssertEqual(directAssessment.incompatibility, .insecureTransport)
        XCTAssertTrue(serverAssessment.isPlayable)
        XCTAssertEqual(serverAssessment.kind, .hls)
    }

    func testRejectsStreamingServerOutputFromDifferentOrigin() throws {
        let endpoint = try StreamingServerEndpoint("https://stream.example.test:11470")
        let output = try XCTUnwrap(
            URL(string: "https://other.example.test:11470/hlsv2/session/master.m3u8")
        )

        let result = WatchStreamCompatibility.assessStreamingServerURL(
            output,
            endpoint: endpoint
        )

        XCTAssertEqual(result.incompatibility, .untrustedStreamingServerOutput)
    }

    func testFallbackPolicyMovesSelectionFirstAndDeduplicatesSources() throws {
        let first = WatchPlaybackSource(
            providerName: "Provider A",
            stream: directStream("https://media.example.test/first.mp4")
        )
        let selected = WatchPlaybackSource(
            providerName: "Provider B",
            stream: directStream("https://media.example.test/selected.m3u8")
        )

        let ordered = WatchPlaybackFallbackPolicy.ordered(
            sources: [first, selected, first],
            selectedSourceID: selected.id
        )

        XCTAssertEqual(ordered, [selected, first])
        XCTAssertEqual(
            WatchPlaybackFallbackPolicy.nextIndex(after: 0, sourceCount: ordered.count),
            1
        )
        XCTAssertNil(
            WatchPlaybackFallbackPolicy.nextIndex(after: 1, sourceCount: ordered.count)
        )
    }

    func testPlaybackPersistencePolicyRemovesCredentialsAndTransientURLFields() throws {
        let input = try XCTUnwrap(
            URL(
                string: "https://user:password@media.example.test/poster.jpg"
                    + "?token=secret&expires=123#preview"
            )
        )

        let sanitized = try XCTUnwrap(
            WatchPlaybackPersistencePolicy.sanitizedReferenceURL(input)
        )

        XCTAssertEqual(sanitized.absoluteString, "https://media.example.test/poster.jpg")
        XCTAssertNil(URLComponents(url: sanitized, resolvingAgainstBaseURL: false)?.user)
        XCTAssertNil(URLComponents(url: sanitized, resolvingAgainstBaseURL: false)?.query)
    }

    func testPlaybackPersistencePolicyRejectsNonNetworkReferences() throws {
        XCTAssertNil(
            WatchPlaybackPersistencePolicy.sanitizedReferenceURL(
                URL(fileURLWithPath: "/private/tmp/source.m3u8")
            )
        )
        XCTAssertNil(
            WatchPlaybackPersistencePolicy.sanitizedReferenceURL(
                URL(string: "data:video/mp4;base64,AAAA")
            )
        )
    }

    private func directStream(_ value: String) -> StremioSkeletonCore.Stream {
        StremioSkeletonCore.Stream(
            url: URL(string: value),
            externalUrl: nil,
            name: "Direct",
            title: nil,
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
    }
}
