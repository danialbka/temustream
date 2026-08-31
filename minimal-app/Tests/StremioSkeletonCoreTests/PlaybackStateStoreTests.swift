import Foundation
import XCTest
@testable import StremioSkeletonCore

final class PlaybackStateStoreTests: XCTestCase {
    @MainActor
    func testRetainedStoreSurvivesDelayedWriteAcrossProfileReactivation() async throws {
        let url = temporaryURL()
        let registry = FileBackedStoreRegistry<PlaybackStateStore>()
        let original = registry.store(for: url) {
            PlaybackStateStore(fileURL: url)
        }
        let barrier = PlaybackRecordBarrier()
        let delayedRecord = Task {
            await barrier.pause()
            return try await original.record(
                progress(identifier: "first", position: 120, date: 1),
                completionTransition: .noChange
            )
        }
        await barrier.waitUntilPaused()

        let reactivated = registry.store(for: url.standardizedFileURL) {
            PlaybackStateStore(fileURL: url)
        }
        XCTAssertTrue(original === reactivated)
        let preloadedProgress = try await reactivated.snapshot().progress
        XCTAssertEqual(preloadedProgress, [])

        await barrier.release()
        _ = try await delayedRecord.value
        _ = try await reactivated.record(
            progress(identifier: "second", position: 180, date: 2),
            completionTransition: .noChange
        )

        let identifiers = try await PlaybackStateStore(fileURL: url)
            .snapshot().progress.map(\.contentIdentifier)
        XCTAssertEqual(Set(identifiers), Set(["first", "second"]))
    }

    func testCompletionTransitionIsOneAtomicSnapshot() async throws {
        let url = temporaryURL()
        let store = PlaybackStateStore(fileURL: url)
        _ = try await store.record(
            progress(position: 120, date: 1),
            completionTransition: .noChange
        )
        let completed = try await store.record(
            progress(position: 950, date: 2),
            completionTransition: .markCompleted
        )
        let reloaded = try await PlaybackStateStore(fileURL: url).snapshot()

        XCTAssertTrue(completed.progress.isEmpty)
        XCTAssertEqual(completed.completions.map(\.contentIdentifier), ["episode"])
        XCTAssertEqual(reloaded, completed)
    }

    func testReplayTransitionAtomicallyClearsCompletion() async throws {
        let url = temporaryURL()
        let store = PlaybackStateStore(fileURL: url)
        _ = try await store.record(
            progress(position: 950, date: 1),
            completionTransition: .markCompleted
        )
        let replayed = try await store.record(
            progress(position: 120, date: 2),
            completionTransition: .markIncomplete
        )
        let reloaded = try await PlaybackStateStore(fileURL: url).snapshot()

        XCTAssertEqual(replayed.progress.map(\.contentIdentifier), ["episode"])
        XCTAssertTrue(replayed.completions.isEmpty)
        XCTAssertEqual(reloaded, replayed)
    }

    func testFailedAtomicWriteLeavesOldResumeStateOnReopen() async throws {
        let url = temporaryURL()
        _ = try await PlaybackStateStore(fileURL: url).record(
            progress(position: 120, date: 1),
            completionTransition: .noChange
        )
        let failing = PlaybackStateStore(
            fileURL: url,
            persistenceWillWrite: { throw CocoaError(.fileWriteNoPermission) }
        )

        do {
            _ = try await failing.record(
                progress(position: 950, date: 2),
                completionTransition: .markCompleted
            )
            XCTFail("Expected injected atomic-write failure")
        } catch {}

        let reloaded = try await PlaybackStateStore(fileURL: url).snapshot()
        XCTAssertEqual(reloaded.progress.map(\.contentIdentifier), ["episode"])
        XCTAssertTrue(reloaded.completions.isEmpty)
    }

    func testFailedAtomicWriteLeavesOldCompletionOnReopen() async throws {
        let url = temporaryURL()
        _ = try await PlaybackStateStore(fileURL: url).record(
            progress(position: 950, date: 1),
            completionTransition: .markCompleted
        )
        let failing = PlaybackStateStore(
            fileURL: url,
            persistenceWillWrite: { throw CocoaError(.fileWriteNoPermission) }
        )

        do {
            _ = try await failing.record(
                progress(position: 120, date: 2),
                completionTransition: .markIncomplete
            )
            XCTFail("Expected injected atomic-write failure")
        } catch {}

        let reloaded = try await PlaybackStateStore(fileURL: url).snapshot()
        XCTAssertTrue(reloaded.progress.isEmpty)
        XCTAssertEqual(reloaded.completions.map(\.contentIdentifier), ["episode"])
    }

    func testStaleTransitionCannotOverwriteNewerUnifiedState() async throws {
        let store = PlaybackStateStore(fileURL: temporaryURL())
        let completed = try await store.record(
            progress(position: 950, date: 2),
            completionTransition: .markCompleted
        )
        let stale = try await store.record(
            progress(position: 120, date: 1),
            completionTransition: .markIncomplete
        )
        XCTAssertEqual(stale, completed)
    }

    func testLegacyConflictMigratesNewestEventOnce() async throws {
        let root = temporaryURL().deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("playback-state.json")
        let progressURL = root.appendingPathComponent("playback-progress.json")
        let completionURL = root.appendingPathComponent("playback-completions.json")
        _ = try await PlaybackProgressStore(fileURL: progressURL).record(
            progress(position: 120, date: 2)
        )
        _ = try await PlaybackCompletionStore(fileURL: completionURL).markCompleted(
            contentIdentifier: "episode",
            completedAt: Date(timeIntervalSince1970: 1)
        )

        let migrated = try await PlaybackStateStore(
            fileURL: stateURL,
            legacyProgressFileURL: progressURL,
            legacyCompletionFileURL: completionURL
        ).snapshot()

        XCTAssertEqual(migrated.progress.map(\.contentIdentifier), ["episode"])
        XCTAssertTrue(migrated.completions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: progressURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completionURL.path))
    }

    private func progress(
        identifier: String = "episode",
        position: TimeInterval,
        date: TimeInterval
    ) -> PlaybackProgress {
        PlaybackProgress(
            contentIdentifier: identifier,
            contentTitle: "Episode",
            stream: Stream(
                url: URL(string: "https://example.test/video.mp4"),
                externalUrl: nil,
                name: "Direct",
                title: "1080p",
                description: nil,
                infoHash: nil,
                fileIdx: nil,
                sources: nil
            ),
            position: position,
            duration: 1_000,
            updatedAt: Date(timeIntervalSince1970: date)
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("playback-state.json")
    }
}

private actor PlaybackRecordBarrier {
    private var paused = false
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        pausedWaiters.forEach { $0.resume() }
        pausedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            pausedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
