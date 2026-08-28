import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private final class BoundedLoaderURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var stopCount = 0
    private nonisolated(unsafe) static var startCount = 0
    private static let stopCountLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false

    static func resetStopCount() {
        stopCountLock.withLock {
            stopCount = 0
            startCount = 0
        }
    }

    static func observedStopCount() -> Int {
        stopCountLock.withLock { stopCount }
    }

    static func observedStartCount() -> Int {
        stopCountLock.withLock { startCount }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bounded-loader.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.stopCountLock.withLock { Self.startCount += 1 }
        guard let url = request.url else { return }
        switch url.path {
        case "/never":
            respondWithoutFinishing(status: 200, headers: [:])
        case "/exact":
            let rangePreserved = request.value(forHTTPHeaderField: "Range") == "bytes=0-3"
            respond(
                status: rangePreserved ? 206 : 400,
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 0-3/85899345920",
                ],
                chunks: [Data([0, 1, 2, 3])]
            )
        case "/declared-oversized":
            respond(
                status: 200,
                headers: ["Content-Length": "85899345920"],
                chunks: [Data(repeating: 0xaa, count: 32)]
            )
        case "/chunked-range-ignored":
            respond(
                status: 200,
                headers: [:],
                chunks: [Data([0, 1, 2, 3]), Data([4])]
            )
        case "/server-error":
            respond(
                status: 500,
                headers: ["Content-Length": "85899345920"],
                chunks: [Data(repeating: 0xbb, count: 32)]
            )
        default:
            respond(status: 404, headers: [:], chunks: [])
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
        Self.stopCountLock.withLock { Self.stopCount += 1 }
    }

    private func respondWithoutFinishing(
        status: Int,
        headers: [String: String]
    ) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func respond(
        status: Int,
        headers: [String: String],
        chunks: [Data]
    ) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks where !stateLock.withLock({ stopped }) {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if !stateLock.withLock({ stopped }) {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class BoundedHTTPDataLoaderTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLoaderURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func testReturnsExactPartialResponseAndKeepsRangeHeader() async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://bounded-loader.test/exact")))
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")

        let (data, response) = try await BoundedHTTPDataLoader.load(
            request: request,
            maximumBytes: 4,
            configuration: configuration(),
            preserveHeadersAcrossRedirects: ["Range"]
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data([0, 1, 2, 3]))
    }

    func testRejectsDeclaredOversizeBeforeRetainingBody() async throws {
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/declared-oversized"))
        )

        do {
            _ = try await BoundedHTTPDataLoader.load(
                request: request,
                maximumBytes: 4,
                configuration: configuration()
            )
            XCTFail("Expected the declared response size to be rejected")
        } catch let error as BoundedHTTPDataLoaderError {
            XCTAssertEqual(error, .responseTooLarge(4))
        }
    }

    func testRejectsChunkedRangeIgnoringBodyAtTheByteBudget() async throws {
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/chunked-range-ignored"))
        )

        do {
            _ = try await BoundedHTTPDataLoader.load(
                request: request,
                maximumBytes: 4,
                configuration: configuration()
            )
            XCTFail("Expected the streamed response size to be rejected")
        } catch let error as BoundedHTTPDataLoaderError {
            XCTAssertEqual(error, .responseTooLarge(4))
        }
    }

    func testReturnsErrorStatusFromHeadersWithoutDownloadingErrorPage() async throws {
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/server-error"))
        )

        let (data, response) = try await BoundedHTTPDataLoader.load(
            request: request,
            maximumBytes: 4,
            configuration: configuration()
        )

        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
    }

    func testRejectedRedirectDoesNotFollow() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .reject,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "https://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "https://bounded-loader.test/exact"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        var redirectedRequest: URLRequest?

        loader.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination),
            completionHandler: { redirectedRequest = $0 }
        )

        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }

    func testFollowedRedirectRestoresRangeHeader() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: ["Range": "bytes=0-3"]
        )
        let original = try XCTUnwrap(URL(string: "https://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "https://bounded-loader.test/exact"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        var redirectedRequest: URLRequest?

        loader.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination),
            completionHandler: { redirectedRequest = $0 }
        )

        XCTAssertEqual(
            redirectedRequest?.value(forHTTPHeaderField: "Range"),
            "bytes=0-3"
        )
        session.invalidateAndCancel()
    }

    func testCancellationStopsTransport() async throws {
        BoundedLoaderURLProtocol.resetStopCount()
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/never"))
        )
        let loaderConfiguration = configuration()
        let task = Task {
            try await BoundedHTTPDataLoader.load(
                request: request,
                maximumBytes: 4,
                configuration: loaderConfiguration
            )
        }
        for _ in 0..<100 where BoundedLoaderURLProtocol.observedStartCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(BoundedLoaderURLProtocol.observedStartCount(), 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            for _ in 0..<100 where BoundedLoaderURLProtocol.observedStopCount() == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertGreaterThanOrEqual(
                BoundedLoaderURLProtocol.observedStopCount(),
                1
            )
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
