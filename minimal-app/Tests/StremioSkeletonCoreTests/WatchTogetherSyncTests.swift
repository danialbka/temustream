import XCTest
@testable import StremioSkeletonCore

final class WatchTogetherSyncTests: XCTestCase {
    func testTwoClientsProjectTheSameSharedTimelineDespiteDifferentDeliveryTimes() {
        let firstClientOnReceipt = WatchTogetherTiming.projectedPosition(
            itemTime: 42,
            rate: 1,
            commandHostTime: 100,
            localHostTime: 100.05
        )
        let secondClientOnReceipt = WatchTogetherTiming.projectedPosition(
            itemTime: 42,
            rate: 1,
            commandHostTime: 100,
            localHostTime: 100.31
        )

        XCTAssertEqual(firstClientOnReceipt, 42.05, accuracy: 0.001)
        XCTAssertEqual(secondClientOnReceipt, 42.31, accuracy: 0.001)

        let sharedObservationTime = 101.25
        let firstClientExpected = WatchTogetherTiming.projectedPosition(
            itemTime: 42,
            rate: 1,
            commandHostTime: 100,
            localHostTime: sharedObservationTime
        )
        let secondClientExpected = WatchTogetherTiming.projectedPosition(
            itemTime: 42,
            rate: 1,
            commandHostTime: 100,
            localHostTime: sharedObservationTime
        )
        XCTAssertEqual(firstClientExpected, secondClientExpected, accuracy: 0.001)
        XCTAssertEqual(firstClientExpected, 43.25, accuracy: 0.001)
    }

    func testFuturePlayAnchorDoesNotAdvanceBeforeSharedStartTime() {
        XCTAssertEqual(
            WatchTogetherTiming.projectedPosition(
                itemTime: 120,
                rate: 1,
                commandHostTime: 50,
                localHostTime: 49.5
            ),
            120,
            accuracy: 0.001
        )
    }

    func testProjectionClampsToMediaBounds() {
        XCTAssertEqual(
            WatchTogetherTiming.projectedPosition(
                itemTime: 299.8,
                rate: 1,
                commandHostTime: 10,
                localHostTime: 12,
                duration: 300
            ),
            300,
            accuracy: 0.001
        )
    }

    func testCorrectionToleranceAvoidsDecoderJitterButRepairsRealDrift() {
        XCTAssertFalse(
            WatchTogetherTiming.needsCorrection(
                currentPosition: 90.09,
                expectedPosition: 90,
                tolerance: 0.15
            )
        )
        XCTAssertTrue(
            WatchTogetherTiming.needsCorrection(
                currentPosition: 90.4,
                expectedPosition: 90,
                tolerance: 0.15
            )
        )
    }

    func testFallbackIdentityIsStableAndDoesNotExposeInput() {
        let first = WatchTogetherContentIdentity.fallbackIdentifier(
            for: "  Example   Movie  "
        )
        let second = WatchTogetherContentIdentity.fallbackIdentifier(
            for: "example movie"
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("Example"))
        XCTAssertFalse(first.contains("movie"))
    }
}
