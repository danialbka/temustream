import XCTest
@testable import StremioSkeletonCore

final class PlaybackSeekCoordinatorTests: XCTestCase {
    func testCompletionBeforeWaitIsRetained() async {
        let coordinator = PlaybackSeekCoordinator()
        let request = await coordinator.begin(target: 42)
        await coordinator.complete(
            requestID: request.id,
            target: request.target,
            succeeded: true
        )

        let outcome = await coordinator.wait(for: request, timeout: 1)
        XCTAssertEqual(outcome, .completed)
    }

    func testNewRequestSupersedesOldRequestEvenAtSameTarget() async {
        let coordinator = PlaybackSeekCoordinator()
        let oldRequest = await coordinator.begin(target: 42)
        let newRequest = await coordinator.begin(target: 42)

        await coordinator.complete(
            requestID: oldRequest.id,
            target: oldRequest.target,
            succeeded: true
        )
        let oldOutcome = await coordinator.wait(for: oldRequest, timeout: 1)
        XCTAssertEqual(oldOutcome, .superseded)

        await coordinator.complete(
            requestID: newRequest.id,
            target: newRequest.target,
            succeeded: true
        )
        let newOutcome = await coordinator.wait(for: newRequest, timeout: 1)
        XCTAssertEqual(newOutcome, .completed)
    }

    func testMissingCompletionTimesOut() async {
        let coordinator = PlaybackSeekCoordinator()
        let request = await coordinator.begin(target: 84)

        let outcome = await coordinator.wait(for: request, timeout: 0.01)

        XCTAssertEqual(outcome, .timedOut)
    }

    func testFailureIsTerminal() async {
        let coordinator = PlaybackSeekCoordinator()
        let request = await coordinator.begin(target: 21)
        await coordinator.complete(
            requestID: request.id,
            target: request.target,
            succeeded: false
        )

        let outcome = await coordinator.wait(for: request, timeout: 1)
        XCTAssertEqual(outcome, .failed)
    }

    func testOlderCallerCannotSupersedeNewerExplicitRequestID() async {
        let coordinator = PlaybackSeekCoordinator()
        let newer = await coordinator.begin(requestID: 20, target: 50)
        let older = await coordinator.begin(requestID: 19, target: 10)

        let olderOutcome = await coordinator.wait(for: older, timeout: 1)
        XCTAssertEqual(olderOutcome, .superseded)
        await coordinator.complete(
            requestID: newer.id,
            target: newer.target,
            succeeded: true
        )
        let newerOutcome = await coordinator.wait(for: newer, timeout: 1)
        XCTAssertEqual(newerOutcome, .completed)
    }

    func testDiscardConsumesSupersededOutcomeBeforeWait() async {
        let coordinator = PlaybackSeekCoordinator()
        let abandoned = await coordinator.begin(target: 10)
        let current = await coordinator.begin(target: 20)

        await coordinator.discard(abandoned)
        let abandonedOutcome = await coordinator.wait(for: abandoned, timeout: 1)
        XCTAssertEqual(abandonedOutcome, .superseded)

        await coordinator.complete(
            requestID: current.id,
            target: current.target,
            succeeded: true
        )
        let currentOutcome = await coordinator.wait(for: current, timeout: 1)
        XCTAssertEqual(currentOutcome, .completed)
    }

    func testImplicitIdentifierStartsNewNonzeroEpochAfterMaximum() async {
        let coordinator = PlaybackSeekCoordinator()
        let maximum = await coordinator.begin(requestID: .max, target: 10)
        await coordinator.complete(
            requestID: maximum.id,
            target: maximum.target,
            succeeded: true
        )
        let maximumOutcome = await coordinator.wait(for: maximum, timeout: 1)
        XCTAssertEqual(maximumOutcome, .completed)

        let next = await coordinator.begin(target: 20)
        XCTAssertEqual(next.id, 1)
        await coordinator.complete(
            requestID: next.id,
            target: next.target,
            succeeded: true
        )
        let nextOutcome = await coordinator.wait(for: next, timeout: 1)
        XCTAssertEqual(nextOutcome, .completed)
    }

    func testExplicitIdentifierCanStartNewEpochAfterMaximum() async {
        let coordinator = PlaybackSeekCoordinator()
        let maximum = await coordinator.begin(requestID: .max, target: 10)
        await coordinator.complete(
            requestID: maximum.id,
            target: maximum.target,
            succeeded: true
        )
        let maximumOutcome = await coordinator.wait(for: maximum, timeout: 1)
        XCTAssertEqual(maximumOutcome, .completed)

        let next = await coordinator.begin(requestID: 1, target: 20)
        await coordinator.complete(
            requestID: next.id,
            target: next.target,
            succeeded: true
        )
        let nextOutcome = await coordinator.wait(for: next, timeout: 1)
        XCTAssertEqual(nextOutcome, .completed)
    }

    func testNewEpochDoesNotConsumeResolvedOutcomeFromReusedIdentifier() async {
        let coordinator = PlaybackSeekCoordinator()
        let oldFirst = await coordinator.begin(target: 10)
        _ = await coordinator.begin(target: 20)
        let maximum = await coordinator.begin(requestID: .max, target: 30)
        await coordinator.complete(
            requestID: maximum.id,
            target: maximum.target,
            succeeded: true
        )
        _ = await coordinator.wait(for: maximum, timeout: 1)

        let newFirst = await coordinator.begin(target: 40)
        let outcome = await coordinator.wait(for: newFirst, timeout: 0.01)

        XCTAssertEqual(oldFirst.id, newFirst.id)
        XCTAssertEqual(outcome, .timedOut)
    }
}
