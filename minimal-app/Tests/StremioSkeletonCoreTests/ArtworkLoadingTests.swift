import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StremioSkeletonCore

private actor SuspendedArtworkRequestProbe {
    private(set) var startedCount = 0
    private(set) var cancellationCount = 0

    func load(_ url: URL, limits: ArtworkResourceLimits) async -> Data? {
        _ = url
        _ = limits
        startedCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancellationCount += 1
        }
        return nil
    }
}

private actor ControlledArtworkRequestProbe {
    private(set) var startedURLs: [URL] = []
    private var completions: [URL: CheckedContinuation<Data?, Never>] = [:]

    func load(_ url: URL, limits: ArtworkResourceLimits) async -> Data? {
        _ = limits
        startedURLs.append(url)
        return await withCheckedContinuation { continuation in
            completions[url] = continuation
        }
    }

    func complete(_ url: URL, with data: Data?) -> Bool {
        guard let continuation = completions.removeValue(forKey: url) else { return false }
        continuation.resume(returning: data)
        return true
    }

    func hasStarted(_ url: URL) -> Bool {
        startedURLs.contains(url)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    func read() -> Int {
        lock.withLock { value }
    }
}

final class ArtworkLoadingTests: XCTestCase {
    func testInitialTrustAcceptsPublicIPLiteralOnStandardHTTPAndHTTPSPorts() throws {
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://93.184.216.34/poster.jpg"))
            )
        )
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://93.184.216.34/poster.jpg"))
            )
        )
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://93.184.216.34:80/poster.jpg"))
            )
        )
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://93.184.216.34:443/poster.jpg"))
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://93.184.216.34:8080/poster.jpg"))
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://93.184.216.34:8443/poster.jpg"))
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://[64:ff9b::5db8:d822]/poster.jpg"))
            )
        )
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://[64:ff9b::5db8:d822]/poster.jpg"))
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://[2a00:1450:4009:80b::200e]/poster.jpg"))
            )
        )
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://[2a00:1450:4009:80b::200e]/poster.jpg"))
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://1572395042/poster.jpg"))
            )
        )
    }

    func testInitialTrustRequiresHostnameHTTPSAndPort443() throws {
        let publicResolver: (String) -> [[UInt8]]? = { _ in [[93, 184, 216, 34]] }
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://artwork.example/poster.jpg")),
                resolvingWith: publicResolver
            )
        )
        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://artwork.example:443/poster.jpg")),
                resolvingWith: publicResolver
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "http://artwork.example/poster.jpg")),
                resolvingWith: publicResolver
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                try XCTUnwrap(URL(string: "https://artwork.example:8443/poster.jpg")),
                resolvingWith: publicResolver
            )
        )
    }

    func testHostnameTrustAllowsPublicWellKnownNAT64AndRejectsPrivateSynthesis() throws {
        let url = try XCTUnwrap(URL(string: "https://artwork.example/poster.jpg"))
        let publicSynthesis: [UInt8] = [
            0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 93, 184, 216, 34,
        ]
        let privateSynthesis: [UInt8] = [
            0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 10, 0, 0, 1,
        ]

        XCTAssertTrue(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                url,
                resolvingWith: { _ in [publicSynthesis] }
            )
        )
        XCTAssertFalse(
            ArtworkURLTrustPolicy.allowsInitialRequest(
                url,
                resolvingWith: { _ in [privateSynthesis] }
            )
        )
    }

    func testInitialTrustRejectsCredentialsSchemesAndRestrictedDestinations() throws {
        let rejected = [
            "https://user:password@93.184.216.34/poster.jpg",
            "ftp://93.184.216.34/poster.jpg",
            "https://localhost/poster.jpg",
            "https://art.local/poster.jpg",
            "http://127.0.0.1:18766/ui-states/poster-portrait.png",
            "https://127.0.0.1/poster.jpg",
            "https://10.0.0.1/poster.jpg",
            "https://172.16.0.1/poster.jpg",
            "https://192.168.1.1/poster.jpg",
            "https://169.254.169.254/latest/meta-data",
            "https://192.0.2.1/poster.jpg",
            "https://[::1]/poster.jpg",
            "https://[fc00::1]/poster.jpg",
            "https://[fe80::1]/poster.jpg",
            "https://[2001:db8::1]/poster.jpg",
            "https://[2002:5db8:d822::1]/poster.jpg",
            "https://[64:ff9b::a00:1]/poster.jpg",
            "https://[64:ff9b:1::]/poster.jpg",
            "https://[4000::1]/poster.jpg",
        ]

        for value in rejected {
            XCTAssertFalse(
                ArtworkURLTrustPolicy.allowsInitialRequest(
                    try XCTUnwrap(URL(string: value))
                ),
                value
            )
        }
    }

    func testArtworkRedirectRevalidatesRestrictedSameOriginHop() throws {
        let loader = BoundedHTTPDataLoader(
            maximumBytes: 4,
            redirectPolicy: .follow,
            preservedRedirectHeaders: [:],
            redirectValidator: { source, destination in
                ArtworkRedirectTrustPolicy.allows(
                    from: source,
                    to: destination,
                    resolvingWith: { _ in [[127, 0, 0, 1]] }
                )
            }
        )
        // The same textual origin is resolved again for the redirect and now
        // yields loopback, modeling a resolver-state change after initial trust.
        let reboundOrigin = try XCTUnwrap(URL(string: "https://artwork.example/start"))
        let reboundDestination = try XCTUnwrap(URL(string: "https://artwork.example/poster"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: reboundOrigin,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": reboundDestination.absoluteString]
            )
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: reboundOrigin)
        var redirectedRequest: URLRequest?

        loader.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: reboundDestination),
            completionHandler: { redirectedRequest = $0 }
        )

        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }

    func testArtworkRedirectKeepsHTTPSDowngradeRejection() throws {
        let source = try XCTUnwrap(URL(string: "https://93.184.216.34/start"))
        let destination = try XCTUnwrap(URL(string: "http://93.184.216.34/poster"))
        XCTAssertFalse(
            ArtworkRedirectTrustPolicy.allows(from: source, to: destination)
        )
    }

    func testArtworkRedirectRejectsCleartextHostnameAtEveryHop() throws {
        let source = try XCTUnwrap(URL(string: "http://93.184.216.34/start"))
        let destination = try XCTUnwrap(URL(string: "http://artwork.example/poster"))
        XCTAssertFalse(
            ArtworkRedirectTrustPolicy.allows(
                from: source,
                to: destination,
                resolvingWith: { _ in [[93, 184, 216, 34]] }
            )
        )
    }

    func testArtworkSessionIsEphemeralAndHasNoURLCache() {
        let configuration = ArtworkNetworkSessionPolicy.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertEqual(
            configuration.timeoutIntervalForRequest,
            ArtworkNetworkSessionPolicy.requestTimeout
        )
        XCTAssertEqual(
            configuration.timeoutIntervalForResource,
            ArtworkNetworkSessionPolicy.resourceTimeout
        )
    }

    func testWaiterCancellationBeforeAndAfterRegistrationInvokesRemovalAtMostOnce() {
        let beforeRegistration = ArtworkWaiterCancellation()
        let beforeCounter = LockedCounter()
        beforeRegistration.cancel()
        XCTAssertFalse(beforeRegistration.register { beforeCounter.increment() })
        beforeRegistration.cancel()
        beforeRegistration.finish()
        XCTAssertEqual(beforeCounter.read(), 0)

        let afterRegistration = ArtworkWaiterCancellation()
        let afterCounter = LockedCounter()
        XCTAssertTrue(afterRegistration.register { afterCounter.increment() })
        afterRegistration.cancel()
        afterRegistration.cancel()
        afterRegistration.finish()
        XCTAssertEqual(afterCounter.read(), 1)
    }

    func testRapidUniqueRequestsAreRejectedBeforeTransportTaskCreation() async throws {
        let limits = testLimits(
            maximumConcurrentRequests: 2,
            maximumWaitersPerRequest: 2
        )
        let probe = SuspendedArtworkRequestProbe()
        let cache = ArtworkDataCache(
            initialTrustEvaluator: { _ in true },
            requestLoader: { url, limits in await probe.load(url, limits: limits) }
        )
        let urls = (0..<20).map { index in
            URL(string: "https://artwork.example/\(index).jpg")!
        }
        let requests = urls.map { url in
            Task {
                await cache.data(for: url, limits: limits)
            }
        }

        let admitted = await eventually {
            await probe.startedCount == 2
        }
        XCTAssertTrue(admitted)
        let snapshot = await cache.snapshotForTesting()
        XCTAssertEqual(snapshot.inFlightRequestCount, 2)
        XCTAssertLessThanOrEqual(snapshot.waiterCount, 2)
        XCTAssertLessThanOrEqual(snapshot.visibleRetryCount, 4)
        let startedCount = await probe.startedCount
        XCTAssertEqual(startedCount, 2)

        requests.forEach { $0.cancel() }
        for request in requests { _ = await request.value }
        let drained = await eventually {
            await cache.snapshotForTesting().inFlightRequestCount == 0
        }
        XCTAssertTrue(drained)
        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(cancellationCount, 2)
    }

    func testRapidSameURLWaitersAreCappedAndCancellationDrainsFlight() async throws {
        let limits = testLimits(
            maximumConcurrentRequests: 1,
            maximumWaitersPerRequest: 2
        )
        let probe = SuspendedArtworkRequestProbe()
        let cache = ArtworkDataCache(
            initialTrustEvaluator: { _ in true },
            requestLoader: { url, limits in await probe.load(url, limits: limits) }
        )
        let url = try XCTUnwrap(URL(string: "https://artwork.example/shared.jpg"))
        let requests = (0..<20).map { _ in
            Task { await cache.data(for: url, limits: limits) }
        }

        let capped = await eventually {
            let snapshot = await cache.snapshotForTesting()
            let startedCount = await probe.startedCount
            return startedCount == 1 && snapshot.waiterCount == 2
        }
        XCTAssertTrue(capped)
        let snapshot = await cache.snapshotForTesting()
        XCTAssertEqual(snapshot.inFlightRequestCount, 1)
        XCTAssertEqual(snapshot.waiterCount, 2)

        requests.forEach { $0.cancel() }
        for request in requests { _ = await request.value }
        let drained = await eventually {
            await cache.snapshotForTesting().inFlightRequestCount == 0
        }
        XCTAssertTrue(drained)
        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    func testVisibleRequestEventuallyProgressesWhilePrefetchKeepsReservedSlotFree() async throws {
        let limits = testLimits(
            maximumConcurrentRequests: 2,
            maximumWaitersPerRequest: 2
        )
        let probe = ControlledArtworkRequestProbe()
        let cache = ArtworkDataCache(
            initialTrustEvaluator: { _ in true },
            requestLoader: { url, limits in await probe.load(url, limits: limits) }
        )
        let prefetchURL = try XCTUnwrap(URL(string: "https://artwork.example/prefetch-a.jpg"))
        let droppedPrefetchURL = try XCTUnwrap(URL(string: "https://artwork.example/prefetch-b.jpg"))
        let firstVisibleURL = try XCTUnwrap(URL(string: "https://artwork.example/visible-a.jpg"))
        let waitingVisibleURL = try XCTUnwrap(URL(string: "https://artwork.example/visible-b.jpg"))

        let prefetch = Task {
            await cache.data(for: prefetchURL, limits: limits, priority: .prefetch)
        }
        let prefetchStarted = await eventually { await probe.hasStarted(prefetchURL) }
        XCTAssertTrue(prefetchStarted)
        let droppedPrefetch = await cache.data(
            for: droppedPrefetchURL,
            limits: limits,
            priority: .prefetch
        )
        XCTAssertNil(droppedPrefetch)
        let droppedPrefetchStarted = await probe.hasStarted(droppedPrefetchURL)
        XCTAssertFalse(droppedPrefetchStarted)

        let firstVisible = Task { await cache.data(for: firstVisibleURL, limits: limits) }
        let firstVisibleStarted = await eventually { await probe.hasStarted(firstVisibleURL) }
        XCTAssertTrue(firstVisibleStarted)
        let waitingVisible = Task { await cache.data(for: waitingVisibleURL, limits: limits) }
        let visibleIsRetrying = await eventually {
            await cache.snapshotForTesting().visibleRetryCount == 1
        }
        XCTAssertTrue(visibleIsRetrying)

        let completedFirstVisible = await probe.complete(firstVisibleURL, with: Data([1]))
        XCTAssertTrue(completedFirstVisible)
        let firstVisibleResult = await firstVisible.value
        XCTAssertEqual(firstVisibleResult, Data([1]))
        let waitingVisibleStarted = await eventually {
            await probe.hasStarted(waitingVisibleURL)
        }
        XCTAssertTrue(waitingVisibleStarted)

        let completedPrefetch = await probe.complete(prefetchURL, with: Data([2]))
        let completedWaitingVisible = await probe.complete(waitingVisibleURL, with: Data([3]))
        XCTAssertTrue(completedPrefetch)
        XCTAssertTrue(completedWaitingVisible)
        let prefetchResult = await prefetch.value
        let waitingVisibleResult = await waitingVisible.value
        XCTAssertEqual(prefetchResult, Data([2]))
        XCTAssertEqual(waitingVisibleResult, Data([3]))
        let drained = await eventually {
            let snapshot = await cache.snapshotForTesting()
            return snapshot.inFlightRequestCount == 0
                && snapshot.visibleRetryCount == 0
                && snapshot.waiterCount == 0
        }
        XCTAssertTrue(drained)
    }

    func testEncodedBodyBudgetAcceptsBoundaryAndRejectsOversize() {
        let limits = testLimits(maximumEncodedBytes: 4)
        XCTAssertTrue(ArtworkResourcePolicy.allowsEncodedByteCount(4, limits: limits))
        XCTAssertFalse(ArtworkResourcePolicy.allowsEncodedByteCount(5, limits: limits))
        XCTAssertFalse(ArtworkResourcePolicy.allowsEncodedByteCount(0, limits: limits))
    }

    func testDecodedPixelPolicyAcceptsNormalAndRejectsDimensionsAndAggregate() {
        let limits = testLimits(
            maximumDecodedPixels: 100,
            maximumDimension: 10,
            maximumFrameCount: 2
        )
        XCTAssertTrue(
            ArtworkResourcePolicy.allowsDecodedFrames(
                [ArtworkDecodedFrame(width: 10, height: 10)],
                limits: limits
            )
        )
        XCTAssertFalse(
            ArtworkResourcePolicy.allowsDecodedFrames(
                [ArtworkDecodedFrame(width: 11, height: 1)],
                limits: limits
            )
        )
        XCTAssertFalse(
            ArtworkResourcePolicy.allowsDecodedFrames(
                [
                    ArtworkDecodedFrame(width: 10, height: 10),
                    ArtworkDecodedFrame(width: 1, height: 1),
                ],
                limits: limits
            )
        )
        XCTAssertFalse(
            ArtworkResourcePolicy.allowsDecodedFrames(
                [
                    ArtworkDecodedFrame(width: 1, height: 1),
                    ArtworkDecodedFrame(width: 1, height: 1),
                    ArtworkDecodedFrame(width: 1, height: 1),
                ],
                limits: limits
            )
        )
    }

    func testPlatformPixelProfilesCoverDisplayArtworkWithoutWatchFourKDecode() {
        let fullHD = [ArtworkDecodedFrame(width: 1_920, height: 1_080)]
        let fourK = [ArtworkDecodedFrame(width: 3_840, height: 2_160)]

        XCTAssertTrue(
            ArtworkResourcePolicy.allowsDecodedFrames(fullHD, limits: .watch)
        )
        XCTAssertFalse(
            ArtworkResourcePolicy.allowsDecodedFrames(fourK, limits: .watch)
        )
        XCTAssertTrue(
            ArtworkResourcePolicy.allowsDecodedFrames(fourK, limits: .mobile)
        )
        XCTAssertTrue(
            ArtworkResourcePolicy.allowsDecodedFrames(fourK, limits: .television)
        )
    }

    func testImageMetadataInspectionAcceptsSmallPNGAndHonorsBodyLimit() throws {
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        XCTAssertTrue(
            ArtworkResourcePolicy.allowsImageData(
                png,
                limits: testLimits(maximumEncodedBytes: png.count)
            )
        )
        XCTAssertFalse(
            ArtworkResourcePolicy.allowsImageData(
                png,
                limits: testLimits(maximumEncodedBytes: png.count - 1)
            )
        )
    }

    private func testLimits(
        maximumEncodedBytes: Int = 1_024,
        maximumDecodedPixels: Int64 = 1_000_000,
        maximumDimension: Int64 = 1_024,
        maximumFrameCount: Int = 4,
        maximumConcurrentRequests: Int = 4,
        maximumWaitersPerRequest: Int = 8
    ) -> ArtworkResourceLimits {
        ArtworkResourceLimits(
            maximumEncodedBytes: maximumEncodedBytes,
            maximumDecodedPixels: maximumDecodedPixels,
            maximumDimension: maximumDimension,
            maximumFrameCount: maximumFrameCount,
            maximumCacheEntries: 4,
            maximumCacheBytes: 4_096,
            maximumConcurrentRequests: maximumConcurrentRequests,
            maximumWaitersPerRequest: maximumWaitersPerRequest
        )
    }

    private func eventually(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
