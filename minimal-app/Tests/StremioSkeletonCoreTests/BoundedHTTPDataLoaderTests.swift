import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private final class BoundedLoaderURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var stopCount = 0
    private nonisolated(unsafe) static var startCount = 0
    private nonisolated(unsafe) static var dripCount = 0
    private static let stopCountLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false

    static func resetStopCount() {
        stopCountLock.withLock {
            stopCount = 0
            startCount = 0
            dripCount = 0
        }
    }

    static func observedStopCount() -> Int {
        stopCountLock.withLock { stopCount }
    }

    static func observedStartCount() -> Int {
        stopCountLock.withLock { startCount }
    }

    static func observedDripCount() -> Int {
        stopCountLock.withLock { dripCount }
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
        case "/drip":
            respondWithoutFinishing(status: 200, headers: [:])
            drip()
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

    private func drip() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.01) {
            [weak self] in
            guard let self,
                  !self.stateLock.withLock({ self.stopped })
            else { return }
            Self.stopCountLock.withLock { Self.dripCount += 1 }
            self.client?.urlProtocol(self, didLoad: Data([0x20]))
            self.drip()
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

    func testManualRedirectTrustPolicyRejectsPrivateHop() throws {
        let source = try XCTUnwrap(URL(string: "https://api.torbox.app/requestdl"))
        let destination = try XCTUnwrap(URL(string: "https://169.254.169.254/latest/meta-data"))

        XCTAssertFalse(
            BoundedHTTPRedirectTrustPolicy.allows(
                from: source,
                to: destination
            )
        )
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

    func testWholeOperationDeadlineStopsAContinuousSlowDrip() async throws {
        BoundedLoaderURLProtocol.resetStopCount()
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/drip"))
        )
        request.timeoutInterval = 1
        let startedAt = Date()

        do {
            _ = try await BoundedHTTPDataLoader.load(
                request: request,
                maximumBytes: 1_024,
                configuration: configuration(),
                operationTimeout: 0.12
            )
            XCTFail("Expected the whole-operation deadline to terminate the drip")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        XCTAssertGreaterThan(
            BoundedLoaderURLProtocol.observedDripCount(),
            2,
            "The response must make progress so this is not merely an idle-timeout test"
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testRequestBodyLoaderUsesRequestTimeoutAsWholeOperationDeadline() async throws {
        BoundedLoaderURLProtocol.resetStopCount()
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/drip"))
        )
        request.timeoutInterval = 0.12
        let session = URLSession(configuration: configuration())
        defer { session.invalidateAndCancel() }
        let startedAt = Date()

        do {
            _ = try await HTTPRequestBodyLoader.load(
                using: session,
                request: request,
                maximumBytes: 1_024
            )
            XCTFail("Expected the shared request loader to terminate the drip")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        XCTAssertGreaterThan(BoundedLoaderURLProtocol.observedDripCount(), 2)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        for _ in 0..<100 where BoundedLoaderURLProtocol.observedStopCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(BoundedLoaderURLProtocol.observedStopCount(), 1)
    }

    func testRequestBodyLoaderPreservesSessionConfigurationForSmallResponse() async throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/exact"))
        )
        request.timeoutInterval = 0.5
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: configuration())
        defer { session.invalidateAndCancel() }

        let (data, response) = try await HTTPRequestBodyLoader.load(
            using: session,
            request: request,
            maximumBytes: 4
        )

        XCTAssertEqual(data, Data([0, 1, 2, 3]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
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
        let original = try XCTUnwrap(URL(string: "http://bounded-loader.test/original"))
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

    func testFollowedRedirectRejectsLoopbackDestination() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "https://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/private"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
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

    func testFollowedRedirectRejectsPrivateNetworkDestination() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "http://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "http://192.168.1.12/private"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
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

    func testFollowedRedirectAllowsSameOriginLocalDestination() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "http://127.0.0.1:11470/original"))
        let destination = try XCTUnwrap(URL(string: "http://127.0.0.1:11470/next"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
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

        XCTAssertEqual(redirectedRequest?.url, destination)
        session.invalidateAndCancel()
    }

    func testFollowedRedirectAllowsPublicCrossOriginDestination() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "http://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "http://8.8.8.8/next"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        var proposedRequest = URLRequest(url: destination)
        proposedRequest.setValue("Bearer source-secret", forHTTPHeaderField: "Authorization")
        var redirectedRequest: URLRequest?

        loader.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposedRequest,
            completionHandler: { redirectedRequest = $0 }
        )

        XCTAssertEqual(redirectedRequest?.url, destination)
        XCTAssertNil(redirectedRequest?.value(forHTTPHeaderField: "Authorization"))
        session.invalidateAndCancel()
    }

    func testFollowedRedirectRejectsCrossOriginPostBody() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "https://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "https://8.8.8.8/next"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        var originalRequest = URLRequest(url: original)
        originalRequest.httpMethod = "POST"
        originalRequest.httpBody = Data("authKey=source-secret".utf8)
        var proposedRequest = URLRequest(url: destination)
        proposedRequest.httpMethod = "POST"
        proposedRequest.httpBody = originalRequest.httpBody
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: originalRequest)
        var redirectedRequest: URLRequest?

        loader.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposedRequest,
            completionHandler: { redirectedRequest = $0 }
        )

        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }

    func testFollowedRedirectRejectsHTTPSDowngrade() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:]
        )
        let original = try XCTUnwrap(URL(string: "https://bounded-loader.test/original"))
        let destination = try XCTUnwrap(URL(string: "http://8.8.8.8/next"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
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

    func testRequestBodyLoaderRejectsOversizedInjectedResponse() async throws {
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://bounded-loader.test/injected"))
        )
        do {
            _ = try await HTTPRequestBodyLoader.load(
                using: OversizedRequestLoader(),
                request: request,
                maximumBytes: 4
            )
            XCTFail("Expected the injected response body to be rejected")
        } catch let error as BoundedHTTPDataLoaderError {
            XCTAssertEqual(error, .responseTooLarge(4))
        }
    }
}

private struct OversizedRequestLoader: HTTPRequestLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(repeating: 0xA5, count: 5), response)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
