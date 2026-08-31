import Foundation
import XCTest
@testable import StremioSkeletonCore

private struct TestTransitionRecord: PlaybackTransitionRecord {
    let contentIdentifier: String
    let position: TimeInterval
    let duration: TimeInterval
    let updatedAt: Date

    var playbackPersistenceSafe: TestTransitionRecord? {
        guard PlaybackProgress.isRepresentableTimelineValue(position),
              PlaybackProgress.isRepresentableTimelineValue(duration)
        else { return nil }
        return self
    }
}

private final class PlaybackTransitionWriteFailpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    func setFailure(_ value: Bool) {
        lock.lock()
        shouldFail = value
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let fail = shouldFail
        lock.unlock()
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
}

final class PlaybackTransitionStoreTests: XCTestCase {
    func testCompletionTransitionIsOneAtomicWrite() async throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("playback-state.json")
        let failpoint = PlaybackTransitionWriteFailpoint()
        let store = PlaybackTransitionStore<TestTransitionRecord>(
            fileURL: stateURL,
            persistenceWillWrite: { try failpoint.check() }
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let completedAt = Date(timeIntervalSince1970: 2_000)
        let started = TestTransitionRecord(
            contentIdentifier: "series:a:episode:1",
            position: 20,
            duration: 100,
            updatedAt: startedAt
        )
        _ = try await store.record(started, completionTransition: .markIncomplete)

        failpoint.setFailure(true)
        let completed = TestTransitionRecord(
            contentIdentifier: started.contentIdentifier,
            position: 99,
            duration: 100,
            updatedAt: completedAt
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.record(
                completed,
                completionTransition: .markCompleted
            )
        }

        let afterFailure = try await PlaybackTransitionStore<TestTransitionRecord>(
            fileURL: stateURL
        ).snapshot()
        XCTAssertEqual(afterFailure.progress, [started])
        XCTAssertTrue(afterFailure.completions.isEmpty)

        failpoint.setFailure(false)
        let committed = try await store.record(
            completed,
            completionTransition: .markCompleted
        )
        XCTAssertTrue(committed.progress.isEmpty)
        XCTAssertEqual(
            committed.completions,
            [PlaybackCompletion(
                contentIdentifier: completed.contentIdentifier,
                completedAt: completedAt
            )]
        )
    }

    func testMigratesLegacyProgressAndCompletionIntoOneDocument() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stateURL = directory.appendingPathComponent("playback-state.json")
        let progressURL = directory.appendingPathComponent("playback-progress.json")
        let completionURL = directory.appendingPathComponent("playback-completions.json")
        let older = TestTransitionRecord(
            contentIdentifier: "episode:older-completion",
            position: 40,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = TestTransitionRecord(
            contentIdentifier: "episode:newer-progress",
            position: 50,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([older, newer]).write(to: progressURL)
        try encoder.encode([
            PlaybackCompletion(
                contentIdentifier: older.contentIdentifier,
                completedAt: Date(timeIntervalSince1970: 2_000)
            ),
            PlaybackCompletion(
                contentIdentifier: newer.contentIdentifier,
                completedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ]).write(to: completionURL)

        let migrated = try await PlaybackTransitionStore<TestTransitionRecord>(
            fileURL: stateURL,
            legacyProgressFileURL: progressURL,
            legacyCompletionFileURL: completionURL
        ).snapshot()

        XCTAssertEqual(migrated.progress, [newer])
        XCTAssertEqual(
            migrated.completions.map(\.contentIdentifier),
            [older.contentIdentifier]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: progressURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completionURL.path))
    }

    func testReplayTransitionIsOneAtomicWrite() async throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("playback-state.json")
        let failpoint = PlaybackTransitionWriteFailpoint()
        let store = PlaybackTransitionStore<TestTransitionRecord>(
            fileURL: stateURL,
            persistenceWillWrite: { try failpoint.check() }
        )
        let identifier = "series:a:episode:replay"
        _ = try await store.record(
            TestTransitionRecord(
                contentIdentifier: identifier,
                position: 99,
                duration: 100,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            completionTransition: .markCompleted
        )

        let replay = TestTransitionRecord(
            contentIdentifier: identifier,
            position: 20,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        failpoint.setFailure(true)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.record(
                replay,
                completionTransition: .markIncomplete
            )
        }
        let afterFailure = try await PlaybackTransitionStore<TestTransitionRecord>(
            fileURL: stateURL
        ).snapshot()
        XCTAssertTrue(afterFailure.progress.isEmpty)
        XCTAssertEqual(afterFailure.completions.map(\.contentIdentifier), [identifier])

        failpoint.setFailure(false)
        let committed = try await store.record(
            replay,
            completionTransition: .markIncomplete
        )
        XCTAssertEqual(committed.progress, [replay])
        XCTAssertTrue(committed.completions.isEmpty)
    }

    func testRemovingResumeKeepsCompletionMarker() async throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("playback-state.json")
        let store = PlaybackTransitionStore<TestTransitionRecord>(fileURL: stateURL)
        let identifier = "series:a:episode:1"
        _ = try await store.record(
            TestTransitionRecord(
                contentIdentifier: identifier,
                position: 99,
                duration: 100,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            completionTransition: .markCompleted
        )
        let state = try await store.removeProgress(
            contentIdentifier: identifier,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertTrue(state.progress.isEmpty)
        XCTAssertEqual(state.completions.map(\.contentIdentifier), [identifier])
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
