import Foundation
import XCTest
@testable import StremioSkeletonCore

final class AddonEndpointTests: XCTestCase {
    func testNormalizesManifestInput() throws {
        let endpoint = try AddonEndpoint(manifestInput: "https://example.com/addon/")
        XCTAssertEqual(endpoint.manifestURL.absoluteString, "https://example.com/addon/manifest.json")
    }

    func testRejectsInsecureRemoteManifest() {
        XCTAssertThrowsError(try AddonEndpoint(manifestInput: "http://example.com/manifest.json"))
    }

    func testRejectsManifestCredentialsInAuthority() {
        XCTAssertThrowsError(
            try AddonEndpoint(manifestInput: "https://user:password@example.com/manifest.json")
        )
    }

    func testAllowsLoopbackHTTPForDevelopment() throws {
        let endpoint = try AddonEndpoint(manifestInput: "http://127.0.0.1:8765/manifest.json")
        XCTAssertEqual(endpoint.manifestURL.host, "127.0.0.1")
    }

    func testBuildsCatalogSearchResource() throws {
        let endpoint = try AddonEndpoint(manifestInput: "https://example.com/manifest.json")
        let url = try endpoint.catalogURL(type: "movie", id: "top", search: "big buck bunny")
        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/catalog/movie/top/search=big%20buck%20bunny.json"
        )
    }

    func testBuildsCatalogSearchAndPaginationResource() throws {
        let endpoint = try AddonEndpoint(manifestInput: "https://example.com/manifest.json")
        let url = try endpoint.catalogURL(
            type: "movie",
            id: "top",
            search: "science fiction",
            skip: 50
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/catalog/movie/top/search=science%20fiction&skip=50.json"
        )
    }

    func testEscapesReservedCharactersInsideCatalogSearchValue() throws {
        let endpoint = try AddonEndpoint(manifestInput: "https://example.com/manifest.json")
        let url = try endpoint.catalogURL(
            type: "movie",
            id: "top",
            search: "rock & roll/100%?#=yes",
            skip: 50
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/catalog/movie/top/"
                + "search=rock%20%26%20roll%2F100%25%3F%23%3Dyes&skip=50.json"
        )
    }
}
